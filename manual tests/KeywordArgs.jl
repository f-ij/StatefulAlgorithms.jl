using SparseArrays, BenchmarkTools

const state = rand(1000)
const sparse_matrix = sprand(1000, 1000, 0.001)

function loop(func, args)
    loopidx=1
    ti = time_ns()
    for _ in 1:10000000
        @inline choose_j(func, args)
        loopidx += 1
    end
    tf = time_ns()
    println("The normal loop took $(tf-ti) ns")
    println("Updates per sec: $(loopidx / (tf-ti) * 1e9)")
end

function loopkw(func, args)
    loopidx=1
    ti = time_ns()
    for _ in 1:10000000
        @inline choose_j_kw(func, args)
        loopidx += 1
    end
    tf = time_ns()
    println("The kw loop took $(tf-ti) ns")
    println("Updates per sec: $(loopidx / (tf-ti) * 1e9)")
end

function collectargs(args, j)
    (;state, sparse_matrix) = args
    cumsum = zero(Float64)
    for ptr in nzrange(sparse_matrix, j)
        smij = sparse_matrix.nzval[ptr]
        i = sparse_matrix.rowval[ptr]
        cumsum += state[i] * smij
    end
    return cumsum*(2*state[j])
end

function collectargskw(args; j)
    (;state, sparse_matrix) = args
    cumsum = zero(Float64)
    for ptr in nzrange(sparse_matrix, j)
        smij = sparse_matrix.nzval[ptr]
        i = sparse_matrix.rowval[ptr]
        cumsum += state[i] * smij
    end
    return cumsum*(2*state[j])
end

function indirection(@specialize(func), args, j)
    @inline func(args, j)
end

function indirection_kw(@specialize(func), args; j)
    @inline func(args; j)
end

function choose_j(@specialize(func), args)
    j = rand(1:1000)
    @inline func(args, j)
    # @inline indirection(func, args, j)
end

function choose_j_kw(@specialize(func), args)
    j = rand(1:1000)
    @inline func(args; j)
    # @inline indirection_kw(func, args; j)
end

loop(collectargs, (;state, sparse_matrix))
loopkw(collectargskw, (;state, sparse_matrix))