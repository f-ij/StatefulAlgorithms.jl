using SparseArrays, BenchmarkTools

const state = rand(1000)
const sparse_matrix = sprand(1000, 1000, 0.001)

function loop(func::F, args) where F
    loopidx=1
    ti = time_ns()
    for _ in 1:10000000
        @inline func(args)
        loopidx += 1
    end
    tf = time_ns()
    println("The $func loop took $(tf-ti) ns")
    println("Updates per sec: $(loopidx / (tf-ti) * 1e9)")
end

function collectargs(args::A, j) where A
    (;state, sparse_matrix) = args
    cumsum = zero(Float64)
    for ptr in nzrange(sparse_matrix, j)
        smij = sparse_matrix.nzval[ptr]
        i = sparse_matrix.rowval[ptr]
        cumsum += state[i] * smij
    end
    return cumsum*(2*state[j])
end

function mmc_choose(args::A) where A
    j = rand(1:1000)
    @inline mmc(args, j)
end

function mmc_choose_kw(args::A) where A
    j = rand(1:1000)
    # @inline mmc_kw(args; j)
    @inline mmc_kw(args; j)
end

function mmc(args::A, j) where A
    T = 2
    dE = @inline collectargs(args, j)
    exp_fac = exp(-dE/T)
    if rand() < exp_fac
        state[j] = -state[j]
    end
end

function mmc_kw(args::A; j) where A
    T = 2
    dE = @inline collectargs(args, j)
    exp_fac = exp(-dE/T)
    if rand() < exp_fac
        state[j] = -state[j]
    end
end

loop(mmc_choose, (;state, sparse_matrix))
loop(mmc_choose_kw, (;state, sparse_matrix))

