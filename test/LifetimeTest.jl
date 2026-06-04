using Test
using StatefulAlgorithms

@testset "Additional lifetime variants" begin
    struct LifetimeCounter <: ProcessAlgorithm end

    function StatefulAlgorithms.init(::LifetimeCounter, context)
        return (; count = 0)
    end

    function StatefulAlgorithms.step!(::LifetimeCounter, context)
        return (; count = context.count + 1)
    end

    atleast_process = InlineProcess(
        LifetimeCounter;
        lifetime = StatefulAlgorithms.AtLeast(x -> x >= 1, 4, Var(LifetimeCounter, :count)),
    )
    atleast_context = run(atleast_process)
    @test atleast_context[LifetimeCounter].count == 4

    early_stop_process = InlineProcess(
        LifetimeCounter;
        lifetime = StatefulAlgorithms.AtLeastAtMost(x -> x >= 4, 3, 10, Var(LifetimeCounter, :count)),
    )
    early_stop_context = run(early_stop_process)
    @test early_stop_context[LifetimeCounter].count == 4

    capped_process = Process(
        LifetimeCounter;
        lifetime = StatefulAlgorithms.AtLeastAtMost(x -> x >= 10, 3, 5, Var(LifetimeCounter, :count)),
    )
    run(capped_process)
    capped_context = fetch(capped_process)
    @test capped_context[LifetimeCounter].count == 5
end

@testset "Condition lifetimes run cleanup on natural completion" begin
    struct LifetimeCleanupCounter <: ProcessAlgorithm end

    function StatefulAlgorithms.init(::LifetimeCleanupCounter, context)
        return (; count = 0, cleaned = false)
    end

    function StatefulAlgorithms.step!(::LifetimeCleanupCounter, context)
        return (; count = context.count + 1)
    end

    function StatefulAlgorithms.cleanup(::LifetimeCleanupCounter, context)
        return (; cleaned = true)
    end

    p = Process(
        LifetimeCleanupCounter;
        lifetime = StatefulAlgorithms.Until(x -> x >= 2, Var(LifetimeCleanupCounter, :count)),
    )
    run(p)
    ctx = fetch(p)

    @test ctx[LifetimeCleanupCounter].count == 2
    @test ctx[LifetimeCleanupCounter].cleaned
    @test context(p)[LifetimeCleanupCounter].cleaned
end

@testset "Indefinite close cleans up and pause preserves live context" begin
    struct LifetimeIndefiniteCleanupCounter <: ProcessAlgorithm end

    function StatefulAlgorithms.init(::LifetimeIndefiniteCleanupCounter, context)
        return (; count = 0, cleaned = false)
    end

    function StatefulAlgorithms.step!(::LifetimeIndefiniteCleanupCounter, context)
        sleep(0.001)
        return (; count = context.count + 1)
    end

    function StatefulAlgorithms.cleanup(::LifetimeIndefiniteCleanupCounter, context)
        return (; cleaned = true)
    end

    closed = Process(LifetimeIndefiniteCleanupCounter; lifetime = StatefulAlgorithms.Indefinite())
    run(closed)
    sleep(0.02)
    close(closed)
    @test context(closed)[LifetimeIndefiniteCleanupCounter].cleaned

    paused = Process(LifetimeIndefiniteCleanupCounter; lifetime = StatefulAlgorithms.Indefinite())
    run(paused)
    sleep(0.02)
    pause(paused)
    wait(paused)
    @test !context(paused)[LifetimeIndefiniteCleanupCounter].cleaned

    close(paused)
    @test context(paused)[LifetimeIndefiniteCleanupCounter].cleaned
end
