# Native execution support

export @cuda, cudaconvert, cufunction, dynamic_cufunction, nearest_warpsize


## helper functions

# split keyword arguments to `@cuda` into ones affecting the macro itself, the compiler and
# the code it generates, or the execution
function split_kwargs(kwargs)
    macro_kws    = [:dynamic]
    compiler_kws = [:minthreads, :maxthreads, :blocks_per_sm, :maxregs, :name]
    call_kws     = [:cooperative, :blocks, :threads, :config, :shmem, :stream]
    macro_kwargs = []
    compiler_kwargs = []
    call_kwargs = []
    for kwarg in kwargs
        if Meta.isexpr(kwarg, :(=))
            key,val = kwarg.args
            if isa(key, Symbol)
                if key in macro_kws
                    push!(macro_kwargs, kwarg)
                elseif key in compiler_kws
                    push!(compiler_kwargs, kwarg)
                elseif key in call_kws
                    push!(call_kwargs, kwarg)
                else
                    throw(ArgumentError("unknown keyword argument '$key'"))
                end
            else
                throw(ArgumentError("non-symbolic keyword '$key'"))
            end
        else
            throw(ArgumentError("non-keyword argument like option '$kwarg'"))
        end
    end

    return macro_kwargs, compiler_kwargs, call_kwargs
end

# assign arguments to variables, handle splatting
function assign_args!(code, args)
    # handle splatting
    splats = map(arg -> Meta.isexpr(arg, :(...)), args)
    args = map(args, splats) do arg, splat
        splat ? arg.args[1] : arg
    end

    # assign arguments to variables
    vars = Tuple(gensym() for arg in args)
    map(vars, args) do var,arg
        push!(code.args, :($var = $(esc(arg))))
    end

    # convert the arguments, compile the function and call the kernel
    # while keeping the original arguments alive
    var_exprs = map(vars, args, splats) do var, arg, splat
         splat ? Expr(:(...), var) : var
    end

    return vars, var_exprs
end

# fast lookup of global world age
world_age() = ccall(:jl_get_tls_world_age, UInt, ())

# slow lookup of local method age
function method_age(f, t)::UInt
    for m in Base._methods(f, t, 1, typemax(UInt))
        if VERSION >= v"1.2.0-DEV.573"
            return m[3].primary_world
        else
            return m[3].min_world
        end
    end

    tt = Base.to_tuple_type(t)
    throw(MethodError(f, tt))
end


## high-level @cuda interface

"""
    @cuda [kwargs...] func(args...)

High-level interface for executing code on a GPU. The `@cuda` macro should prefix a call,
with `func` a callable function or object that should return nothing. It will be compiled to
a CUDA function upon first use, and to a certain extent arguments will be converted and
managed automatically using `cudaconvert`. Finally, a call to `CUDAdrv.cudacall` is
performed, scheduling a kernel launch on the current CUDA context.

Several keyword arguments are supported that influence the behavior of `@cuda`.
- `dynamic`: use dynamic parallelism to launch device-side kernels
- arguments that influence kernel compilation: see [`cufunction`](@ref) and
  [`dynamic_cufunction`](@ref)
- arguments that influence kernel launch: see [`CUDAnative.HostKernel`](@ref) and
  [`CUDAnative.DeviceKernel`](@ref)

The underlying operations (argument conversion, kernel compilation, kernel call) can be
performed explicitly when more control is needed, e.g. to reflect on the resource usage of a
kernel to determine the launch configuration. A host-side kernel launch is done as follows:

    args = ...
    GC.@preserve args begin
        kernel_args = cudaconvert.(args)
        kernel_tt = Tuple{Core.Typeof.(kernel_args)...}
        kernel = cufunction(f, kernel_tt; compilation_kwargs)
        kernel(kernel_args...; launch_kwargs)
    end

A device-side launch, aka. dynamic parallelism, is similar but more restricted:

    args = ...
    # GC.@preserve is not supported
    # we're on the device already, so no need to cudaconvert
    kernel_tt = Tuple{Core.Typeof(args[1]), ...}    # this needs to be fully inferred!
    kernel = dynamic_cufunction(f, kernel_tt)       # no compiler kwargs supported
    kernel(args...; launch_kwargs)
"""
macro cuda(ex...)
    # destructure the `@cuda` expression
    if length(ex) > 0 && ex[1].head == :tuple
        error("The tuple argument to @cuda has been replaced by keywords: `@cuda threads=... fun(args...)`")
    end
    call = ex[end]
    kwargs = ex[1:end-1]

    # destructure the kernel call
    if call.head != :call
        throw(ArgumentError("second argument to @cuda should be a function call"))
    end
    f = call.args[1]
    args = call.args[2:end]

    code = quote end
    macro_kwargs, compiler_kwargs, call_kwargs = split_kwargs(kwargs)
    vars, var_exprs = assign_args!(code, args)

    # handle keyword arguments that influence the macro's behavior
    dynamic = false
    for kwarg in macro_kwargs
        key,val = kwarg.args
        if key == :dynamic
            isa(val, Bool) || throw(ArgumentError("`dynamic` keyword argument to @cuda should be a constant value"))
            dynamic = val::Bool
        else
            throw(ArgumentError("Unsupported keyword argument '$key'"))
        end
    end

    if dynamic
        # FIXME: we could probably somehow support kwargs with constant values by either
        #        saving them in a global Dict here, or trying to pick them up from the Julia
        #        IR when processing the dynamic parallelism marker
        isempty(compiler_kwargs) || error("@cuda dynamic parallelism does not support compiler keyword arguments")

        # dynamic, device-side kernel launch
        push!(code.args,
            quote
                # we're in kernel land already, so no need to cudaconvert arguments
                local kernel_tt = Tuple{$((:(Core.Typeof($var)) for var in var_exprs)...)}
                local kernel = dynamic_cufunction($(esc(f)), kernel_tt)
                kernel($(var_exprs...); $(map(esc, call_kwargs)...))
             end)
    else
        # regular, host-side kernel launch
        #
        # convert the arguments, call the compiler and launch the kernel
        # while keeping the original arguments alive
        push!(code.args,
            quote
                GC.@preserve $(vars...) begin
                    local kernel_args = map(cudaconvert, ($(var_exprs...),))
                    local kernel_tt = Tuple{Core.Typeof.(kernel_args)...}
                    local kernel = cufunction($(esc(f)), kernel_tt;
                                              $(map(esc, compiler_kwargs)...))
                    kernel(kernel_args...; $(map(esc, call_kwargs)...))
                end
             end)
    end

    return code
end


## host to device value conversion

struct Adaptor end

# convert CUDAdrv pointers to CUDAnative pointers
Adapt.adapt_storage(to::Adaptor, p::CuPtr{T}) where {T} = DevicePtr{T,AS.Generic}(p)

# Base.RefValue isn't GPU compatible, so provide a compatible alternative
struct CuRefValue{T} <: Ref{T}
  x::T
end
Base.getindex(r::CuRefValue) = r.x
Adapt.adapt_structure(to::Adaptor, r::Base.RefValue) = CuRefValue(adapt(to, r[]))

"""
    cudaconvert(x)

This function is called for every argument to be passed to a kernel, allowing it to be
converted to a GPU-friendly format. By default, the function does nothing and returns the
input object `x` as-is.

Do not add methods to this function, but instead extend the underlying Adapt.jl package and
register methods for the the `CUDAnative.Adaptor` type.
"""
cudaconvert(arg) = adapt(Adaptor(), arg)


## abstract kernel functionality

abstract type AbstractKernel{F,TT} end

# FIXME: there doesn't seem to be a way to access the documentation for the call-syntax,
#        so attach it to the type -- https://github.com/JuliaDocs/Documenter.jl/issues/558

"""
    (::HostKernel)(args...; kwargs...)
    (::DeviceKernel)(args...; kwargs...)

Low-level interface to call a compiled kernel, passing GPU-compatible arguments in `args`.
For a higher-level interface, use [`@cuda`](@ref).

The following keyword arguments are supported:
- `threads` (defaults to 1)
- `blocks` (defaults to 1)
- `shmem` (defaults to 0)
- `config`: callback function to dynamically compute the launch configuration.
  should accept a `HostKernel` and return a name tuple with any of the above as fields.
  this functionality is intended to be used in combination with the CUDA occupancy API.
- `stream` (defaults to the default stream)
"""
AbstractKernel

@generated function call(kernel::AbstractKernel{F,TT}, args...; call_kwargs...) where {F,TT}
    sig = Base.signature_type(F, TT)
    args = (:F, (:( args[$i] ) for i in 1:length(args))...)

    # filter out ghost arguments that shouldn't be passed
    to_pass = map(!isghosttype, sig.parameters)
    call_t =                  Type[x[1] for x in zip(sig.parameters,  to_pass) if x[2]]
    call_args = Union{Expr,Symbol}[x[1] for x in zip(args, to_pass)            if x[2]]

    # replace non-isbits arguments (they should be unused, or compilation would have failed)
    # alternatively, make CUDAdrv allow `launch` with non-isbits arguments.
    for (i,dt) in enumerate(call_t)
        if !isbitstype(dt)
            call_t[i] = Ptr{Any}
            call_args[i] = :C_NULL
        end
    end

    # finalize types
    call_tt = Base.to_tuple_type(call_t)

    quote
        Base.@_inline_meta

        cudacall(kernel, $call_tt, $(call_args...); call_kwargs...)
    end
end


## host-side kernels

struct HostKernel{F,TT} <: AbstractKernel{F,TT}
    ctx::CuContext
    mod::CuModule
    fun::CuFunction
end

@doc (@doc AbstractKernel) HostKernel

@inline function cudacall(kernel::HostKernel, tt, args...; config=nothing, kwargs...)
    if config !== nothing
        CUDAdrv.cudacall(kernel.fun, tt, args...; kwargs..., config(kernel)...)
    else
        CUDAdrv.cudacall(kernel.fun, tt, args...; kwargs...)
    end
end

"""
    version(k::HostKernel)

Queries the PTX and SM versions a kernel was compiled for.
Returns a named tuple.
"""
function version(k::HostKernel)
    attr = attributes(k.fun)
    binary_ver = VersionNumber(divrem(attr[CUDAdrv.FUNC_ATTRIBUTE_BINARY_VERSION],10)...)
    ptx_ver = VersionNumber(divrem(attr[CUDAdrv.FUNC_ATTRIBUTE_PTX_VERSION],10)...)
    return (ptx=ptx_ver, binary=binary_ver)
end

"""
    memory(k::HostKernel)

Queries the local, shared and constant memory usage of a compiled kernel in bytes.
Returns a named tuple.
"""
function memory(k::HostKernel)
    attr = attributes(k.fun)
    local_mem = attr[CUDAdrv.FUNC_ATTRIBUTE_LOCAL_SIZE_BYTES]
    shared_mem = attr[CUDAdrv.FUNC_ATTRIBUTE_SHARED_SIZE_BYTES]
    constant_mem = attr[CUDAdrv.FUNC_ATTRIBUTE_CONST_SIZE_BYTES]
    return (:local=>local_mem, shared=shared_mem, constant=constant_mem)
end

"""
    registers(k::HostKernel)

Queries the register usage of a kernel.
"""
function registers(k::HostKernel)
    attr = attributes(k.fun)
    return attr[CUDAdrv.FUNC_ATTRIBUTE_NUM_REGS]
end

"""
    maxthreads(k::HostKernel)

Queries the maximum amount of threads a kernel can use in a single block.
"""
function maxthreads(k::HostKernel)
    attr = attributes(k.fun)
    return attr[CUDAdrv.FUNC_ATTRIBUTE_MAX_THREADS_PER_BLOCK]
end


## host-side API

const agecache = Dict{UInt, UInt}()
const compilecache = Dict{UInt, HostKernel}()
push!(device_reset!_listeners, (dev, ctx) -> begin
    # invalidate compiled kernels when the device resets
    for id in collect(keys(compilecache))
        kernel = compilecache[id]
        if kernel.ctx == ctx
            delete!(compilecache, id)
        end
    end
end)

"""
    cufunction(f, tt=Tuple{}; kwargs...)

Low-level interface to compile a function invocation for the currently-active GPU, returning
a callable kernel object. For a higher-level interface, use [`@cuda`](@ref).

The following keyword arguments are supported:
- `minthreads`: the required number of threads in a thread block
- `maxthreads`: the maximum number of threads in a thread block
- `blocks_per_sm`: a minimum number of thread blocks to be scheduled on a single
  multiprocessor
- `maxregs`: the maximum number of registers to be allocated to a single thread (only
  supported on LLVM 4.0+)
- `name`: override the name that the kernel will have in the generated code

The output of this function is automatically cached, i.e. you can simply call `cufunction`
in a hot path without degrading performance. New code will be generated automatically, when
when function changes, or when different types or keyword arguments are provided.
"""
@generated function cufunction(f::Core.Function, tt::Type=Tuple{}; name=nothing, kwargs...)
    tt = Base.to_tuple_type(tt.parameters[1])
    sig = Base.signature_type(f, tt)
    t = Tuple(tt.parameters)

    precomp_key = hash(sig)  # precomputable part of the keys
    quote
        Base.@_inline_meta

        CUDAnative.maybe_initialize("cufunction")

        # look-up the method age
        key = hash(world_age(), $precomp_key)
        if haskey(agecache, key)
            age = agecache[key]
        else
            age = method_age(f, $t)
            agecache[key] = age
        end

        # generate a key for indexing the compilation cache
        ctx = CuCurrentContext()
        key = hash(age, $precomp_key)
        key = hash(ctx, key)
        key = hash(name, key)
        key = hash(kwargs, key)
        for nf in 1:nfields(f)
            # mix in the values of any captured variable
            key = hash(getfield(f, nf), key)
        end

        # compile the function
        if !haskey(compilecache, key)
            # compile to PTX
            dev = device(ctx)
            cap = supported_capability(dev)
            asm, kernel_fn, undefined_fns =
                compile(:ptx, cap, f, tt; name=name, strict=true, kwargs...)

            # settings to JIT based on Julia's debug setting
            jit_options = Dict{CUDAdrv.CUjit_option,Any}()
            if Base.JLOptions().debug_level == 1
                jit_options[CUDAdrv.JIT_GENERATE_LINE_INFO] = true
            elseif Base.JLOptions().debug_level >= 2
                jit_options[CUDAdrv.JIT_GENERATE_DEBUG_INFO] = true
            end

            # link the CUDA device library
            image = asm
            # linking the device runtime library requires use of the CUDA linker,
            # which in turn switches compilation to device relocatable code (-rdc) mode.
            #
            # even if not doing any actual calls that need -rdc (i.e., calls to the runtime
            # library), this significantly hurts performance, so don't do it unconditionally
            intrinsic_fns = ["vprintf", "malloc", "free", "__assertfail",
                            "__nvvm_reflect" #= TODO: should have been optimized away =#]
            if !isempty(setdiff(undefined_fns, intrinsic_fns))
                @timeit_debug to "device runtime library" begin
                    linker = CUDAdrv.CuLink(jit_options)
                    CUDAdrv.add_file!(linker, libcudadevrt[], CUDAdrv.JIT_INPUT_LIBRARY)
                    CUDAdrv.add_data!(linker, kernel_fn, asm)
                    image = CUDAdrv.complete(linker)
                end
            end

            # JIT into an executable kernel object
            mod = CuModule(image, jit_options)
            fun = CuFunction(mod, kernel_fn)
            kernel = HostKernel{f,tt}(ctx, mod, fun)

            @debug begin
                ver = version(kernel)
                mem = memory(kernel)
                reg = registers(kernel)
                fn = something(name, nameof(f))
                """Compiled $fn to PTX $(ver.ptx) for SM $(ver.binary) using $reg registers.
                   Memory usage: $(Base.format_bytes(mem.local)) local, $(Base.format_bytes(mem.shared)) shared, $(Base.format_bytes(mem.constant)) constant"""
            end
            compilecache[key] = kernel
            create_exceptions!(mod)
        end

        return compilecache[key]::HostKernel{f,tt}
    end
end

# https://github.com/JuliaLang/julia/issues/14919
(kernel::HostKernel)(args...; kwargs...) = call(kernel, args...; kwargs...)


## device-side kernels

struct DeviceKernel{F,TT} <: AbstractKernel{F,TT}
    fun::Ptr{Cvoid}
end

@doc (@doc AbstractKernel) DeviceKernel

@inline cudacall(kernel::DeviceKernel, tt, args...; kwargs...) =
    dynamic_cudacall(kernel.fun, tt, args...; kwargs...)

# FIXME: duplication with CUDAdrv.cudacall
@generated function dynamic_cudacall(f::Ptr{Cvoid}, tt::Type, args...;
                                     blocks=UInt32(1), threads=UInt32(1), shmem=UInt32(0),
                                     stream=CuDefaultStream())
    types = tt.parameters[1].parameters     # the type of `tt` is Type{Tuple{<:DataType...}}

    ex = quote
        Base.@_inline_meta
    end

    # convert the argument values to match the kernel's signature (specified by the user)
    # (this mimics `lower-ccall` in julia-syntax.scm)
    converted_args = Vector{Symbol}(undef, length(args))
    arg_ptrs = Vector{Symbol}(undef, length(args))
    for i in 1:length(args)
        converted_args[i] = gensym()
        arg_ptrs[i] = gensym()
        push!(ex.args, :($(converted_args[i]) = Base.cconvert($(types[i]), args[$i])))
        push!(ex.args, :($(arg_ptrs[i]) = Base.unsafe_convert($(types[i]), $(converted_args[i]))))
    end

    append!(ex.args, (quote
        #GC.@preserve $(converted_args...) begin
            launch(f, blocks, threads, shmem, stream, $(arg_ptrs...))
        #end
    end).args)

    return ex
end


## device-side API

"""
    dynamic_cufunction(f, tt=Tuple{})

Low-level interface to compile a function invocation for the currently-active GPU, returning
a callable kernel object. Device-side equivalent of [`CUDAnative.cufunction`](@ref).

No keyword arguments are supported.
"""
@inline dynamic_cufunction(f::Core.Function, tt::Type=Tuple{}) =
    delayed_cufunction(Val(f), Val(tt))

# marker function that will get picked up during compilation
if VERSION >= v"1.2.0-DEV.512"
    @inline cudanativeCompileKernel(id::Int) =
        ccall("extern cudanativeCompileKernel", llvmcall, Ptr{Cvoid}, (Int,), id)
else
    import Base.Sys: WORD_SIZE
    @eval @inline cudanativeCompileKernel(id::Int) = Base.llvmcall(
        $("declare i$WORD_SIZE @cudanativeCompileKernel(i$WORD_SIZE)",
          "%rv = call i$WORD_SIZE @cudanativeCompileKernel(i$WORD_SIZE %0)
           ret i$WORD_SIZE %rv"), Ptr{Cvoid}, Tuple{Int}, id)
end

const delayed_cufunctions = Vector{Tuple{Core.Function,Type}}()
@generated function delayed_cufunction(::Val{f}, ::Val{tt}) where {f,tt}
    global delayed_cufunctions
    push!(delayed_cufunctions, (f,tt))
    id = length(delayed_cufunctions)

    quote
        # TODO: add an edge to this method instance to support method redefinitions
        fptr = cudanativeCompileKernel($id)
        DeviceKernel{f,tt}(fptr)
    end
end

# https://github.com/JuliaLang/julia/issues/14919
(kernel::DeviceKernel)(args...; kwargs...) = call(kernel, args...; kwargs...)


## other

"""
    nearest_warpsize(dev::CuDevice, threads::Integer)

Return the nearest number of threads that is a multiple of the warp size of a device.

This is a common requirement, eg. when using shuffle intrinsics.
"""
function nearest_warpsize(dev::CuDevice, threads::Integer)
    ws = CUDAdrv.warpsize(dev)
    return threads + (ws - threads % ws) % ws
end
