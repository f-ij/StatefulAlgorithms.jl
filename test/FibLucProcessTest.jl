using Test
using StatefulAlgorithms

@StepAlgorithm function RunFib(@managed(fiblist = (l = Int[0, 1]; processsizehint!(l, context); l)))
    push!(fiblist, fiblist[end] + fiblist[end - 1])
    return
end

@StepAlgorithm function RunLuc(@managed(luclist = (l = Int[2, 1]; processsizehint!(l, context); l)))
    push!(luclist, luclist[end] + luclist[end - 1])
    return
end

@testset "Process run fills context" begin
    n = 50_000
    fibluc = StatefulAlgorithms.CompositeAlgorithm( RunFib, RunLuc , (1, 2))
    p = StatefulAlgorithms.Process(fibluc; repeats = n)
    @test repeats(StatefulAlgorithms.lifetime(p)) == n
    @test_throws ErrorException StatefulAlgorithms.Process(fibluc; lifetime = n)

    @test progress(p) == 0.0

    StatefulAlgorithms.run(p)
    ctx = fetch(p)

    @test progress(p) == 1.0

    fib_ctx = ctx[RunFib]
    luc_ctx = ctx[RunLuc]

    @test length(fib_ctx.fiblist) == n + 2
    @test length(luc_ctx.luclist) == n/2 + 2
end
