using Test
using StatefulAlgorithms

struct RunFib <: StatefulAlgorithms.ProcessAlgorithm end
struct RunLuc <: StatefulAlgorithms.ProcessAlgorithm end

function StatefulAlgorithms.step!(::RunFib, context)
    fiblist = context.fiblist
    push!(fiblist, fiblist[end] + fiblist[end - 1])
    return (;)
end

function StatefulAlgorithms.init(::RunFib, context)
    fiblist = Int[0, 1]
    processsizehint!(fiblist, context)
    return (;fiblist)
end

function StatefulAlgorithms.step!(::RunLuc, context)
    luclist = context.luclist
    push!(luclist, luclist[end] + luclist[end - 1])
    return (;)
end

function StatefulAlgorithms.init(::RunLuc, context)
    luclist = Int[2, 1]
    processsizehint!(luclist, context)
    return (;luclist)
end

@testset "Process run fills context" begin
    n = 50_000
    fibluc = StatefulAlgorithms.CompositeAlgorithm( RunFib, RunLuc , (1, 2))
    p = StatefulAlgorithms.Process(fibluc; repeats = n)
    @test repeats(StatefulAlgorithms.lifetime(p)) == n
    @test_throws ErrorException StatefulAlgorithms.Process(fibluc; lifetime = n)

    StatefulAlgorithms.run(p)
    ctx = fetch(p)

    fib_ctx = ctx[RunFib]
    luc_ctx = ctx[RunLuc]

    @test length(fib_ctx.fiblist) == n + 2
    @test length(luc_ctx.luclist) == n/2 + 2
end
