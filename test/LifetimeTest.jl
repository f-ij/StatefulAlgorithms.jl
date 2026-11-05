using Test
using StatefulAlgorithms

@testset "Additional lifetime variants" begin
    @StepAlgorithm function LifetimeCounter(@managed(count = 0))
        @update count += 1
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

    # The lifetime's condition is checked before every step, like a routine child's before every repeat: if it
    # already holds at the start, no step runs.
    already_done_process = InlineProcess(
        LifetimeCounter;
        lifetime = StatefulAlgorithms.Until(x -> x >= 0, Var(LifetimeCounter, :count)),
    )
    @test run(already_done_process)[LifetimeCounter].count == 0
end

@testset "Condition lifetimes run cleanup on natural completion" begin
    @StepAlgorithm function LifetimeCleanupCounter(@managed(count = 0, cleaned = false))
        @update count += 1
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
    @test getcontext(p)[LifetimeCleanupCounter].cleaned
end

@testset "Indefinite close cleans up and pause preserves live context" begin
    @StepAlgorithm function LifetimeIndefiniteCleanupCounter(@managed(count = 0, cleaned = false))
        sleep(0.001)
        @update count += 1
    end

    function StatefulAlgorithms.cleanup(::LifetimeIndefiniteCleanupCounter, context)
        return (; cleaned = true)
    end

    closed = Process(LifetimeIndefiniteCleanupCounter; lifetime = StatefulAlgorithms.Indefinite())
    run(closed)
    sleep(0.02)
    close(closed)
    @test getcontext(closed)[LifetimeIndefiniteCleanupCounter].cleaned

    paused = Process(LifetimeIndefiniteCleanupCounter; lifetime = StatefulAlgorithms.Indefinite())
    run(paused)
    sleep(0.02)
    pause(paused)
    wait(paused)
    @test !getcontext(paused)[LifetimeIndefiniteCleanupCounter].cleaned

    close(paused)
    @test getcontext(paused)[LifetimeIndefiniteCleanupCounter].cleaned
end

@testset "setcontext! on a Process: idle, and paused" begin
    @StepAlgorithm function SetContextCounter(@managed(count = 0))
        @update count += 1
    end

    p = Process(SetContextCounter; repeats = 2)
    setcontext!(p, first(setup(getalgo(p), Override(SetContextCounter, :count => 100))))
    @test getcontext(p)[SetContextCounter].count == 100
    run(p); wait(p)
    @test getcontext(p)[SetContextCounter].count == 102

    # The setter does not pause: the caller pauses, sets, and resumes.
    paused = Process(SetContextCounter; lifetime = Indefinite())
    run(paused)
    sleep(0.2)
    pause(paused); wait(paused)
    setcontext!(paused, first(setup(getalgo(paused), Override(SetContextCounter, :count => -10^15))))
    @test getcontext(paused)[SetContextCounter].count == -10^15
    run(paused)
    sleep(0.2)
    close(paused)
    @test getcontext(paused)[SetContextCounter].count < 0
end

@testset "A lifetime reading a Unique handle's variable (Var), and the handles read back by the user" begin
    @StepAlgorithm @config step = 1.0 function LifetimeStepper(@managed(x = 0.0))
        @update x += step
    end
    a, b = Unique(LifetimeStepper(step = 1.0)), Unique(LifetimeStepper(step = 10.0))
    # `a` repeats until its own `x` reaches 3 (at most 100), then `b` runs once
    inner = Routine(a, b, (RepeatOrUntil(x -> x >= 3.0, 100, Var(a, :x)), 1))
    context, plan = setup(CompositeAlgorithm(inner, (1,)))
    c, _ = run(plan, context; repeats = 1)
    @test c[a].x == 3.0
    @test c[b].x == 10.0
    @test c[Var(b, :x)] == 10.0
end
