module GPUModule

using CUDA

export vadd

@target ptx function vadd(a_ptr::Ptr{Float32}, b_ptr::Ptr{Float32}, c_ptr::Ptr{Float32})
    a = UnsafeArray(a_ptr)
    b = UnsafeArray(b_ptr)
    c = UnsafeArray(c_ptr)

    i = blockId_x() + (threadId_x()-1) * numBlocks_x()
    c[i] = a[i] + b[i]

    return nothing
end

end

using CUDA, Base.Test
using GPUModule


# set-up

dev = CuDevice(0)
ctx = CuContext(dev)

siz = (3, 4)
len = prod(siz)

initialize_codegen(ctx, dev)


# test 1: manually managed data

a = round(rand(Float32, siz) * 100)
b = round(rand(Float32, siz) * 100)

ga = CuArray(a)
gb = CuArray(b)
gc = CuArray(Float32, siz)

@cuda (len, 1) GPUModule.vadd(ga, gb, gc)
c = to_host(gc)
@test_approx_eq (a + b) c

free(ga)
free(gb)
free(gc)


# test 2: auto-managed host data

a = round(rand(Float32, siz) * 100)
b = round(rand(Float32, siz) * 100)

@cuda (len, 1) GPUModule.vadd(CuIn(a), CuIn(b), CuOut(c))
@test_approx_eq (a + b) c


# test 3: auto-managed host data, without specifying type

a = round(rand(Float32, siz) * 100)
b = round(rand(Float32, siz) * 100)

@cuda (len, 1) GPUModule.vadd(a, b, c)
@test_approx_eq (a + b) c