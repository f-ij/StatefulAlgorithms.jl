using Test
using StatefulAlgorithms

# NestLin1..NestLin4 add 1..4 to `x` each step.
for k in 1:4
    @eval @StepAlgorithm function $(Symbol(:NestLin, k))(@managed(x = 0.0))
        @update x += $k
    end
end

@testset "Loop cursors and conditional schedules" begin
    @StepAlgorithm function LoopCursorIntervalCounter(@managed(count = 0))
        @update count += 1
    end
    @StepAlgorithm function LoopCursorYieldCounter(@managed(count = 0))
        sleep(0.001)
        @update count += 1
    end

    composite = CompositeAlgorithm(LoopCursorIntervalCounter, (2,))
    routine = Routine(LoopCursorIntervalCounter, (3,))
    threaded = ThreadedCompositeAlgorithm(LoopCursorIntervalCounter, (2,))

    @test composite isa StatefulAlgorithms.AbstractPlan
    @test routine isa StatefulAlgorithms.AbstractPlan
    @test threaded isa StatefulAlgorithms.AbstractPlan
    @test !(composite isa StatefulAlgorithms.AbstractLoopAlgorithm)
    @test !(routine isa StatefulAlgorithms.AbstractLoopAlgorithm)
    @test !(threaded isa StatefulAlgorithms.AbstractLoopAlgorithm)
    @test !(composite isa StatefulAlgorithms.SteppableAlgorithm)
    @test !(routine isa StatefulAlgorithms.SteppableAlgorithm)
    @test !(threaded isa StatefulAlgorithms.SteppableAlgorithm)
    @test !hasfield(typeof(composite), :inc)
    @test !hasfield(typeof(routine), :resume_idxs)
    @test !hasfield(typeof(threaded), :inc)
    @test !hasfield(typeof(threaded), :reg)

    resolved = resolve(composite)
    @test resolved isa StatefulAlgorithms.LoopAlgorithm
    @test StatefulAlgorithms.isresolved(resolved)
    @test !StatefulAlgorithms.isresolved(composite)

    initialized = init(composite)
    p1 = Process(initialized; repeats = 1)
    p2 = Process(initialized; repeats = 1)
    run(p1); wait(p1)
    run(p2); wait(p2)
    @test context(p1)[LoopCursorIntervalCounter].count == 0
    @test context(p2)[LoopCursorIntervalCounter].count == 0
    @test isnothing(p1.loop_cursor)
    @test isnothing(p2.loop_cursor)

    direct_cursor = StatefulAlgorithms.loop_cursor(routine, Val(false))
    pausable_cursor = StatefulAlgorithms.loop_cursor(routine, Val(true))
    @test direct_cursor isa StatefulAlgorithms.DirectRoutineCursor
    @test StatefulAlgorithms.resume_idxs(direct_cursor) == ()
    @test pausable_cursor isa StatefulAlgorithms.PausableRoutineCursor
    @test StatefulAlgorithms.resume_idxs(pausable_cursor) isa StatefulAlgorithms.TupleBox{1, Int}

    long_routine = init(Routine(LoopCursorYieldCounter, (10^8,)))
    paused = Process(long_routine; lifetime = Indefinite())
    run(paused)
    sleep(0.01)
    pause(paused)
    wait(paused)
    @test paused.loop_cursor isa StatefulAlgorithms.PausableRoutineCursor
    @test !isempty(StatefulAlgorithms.resume_idxs(paused.loop_cursor))
    resumed_cursor = @inferred StatefulAlgorithms._loop_cursor(paused, StatefulAlgorithms.getplan(paused.algo), StatefulAlgorithms.Resuming{true}())
    @test resumed_cursor === paused.loop_cursor
    @test @inferred(StatefulAlgorithms.getloopcursor(paused)) === paused.loop_cursor
    close(paused)
    @test isnothing(paused.loop_cursor)
    @test_throws TypeError StatefulAlgorithms.getloopcursor(paused)

    struct LoopRunIfFlag <: AlgoState end
    StatefulAlgorithms.init(::LoopRunIfFlag, context) = (; enabled = false)
    @StepAlgorithm function LoopRunIfCounter(@managed(count = 0))
        @update count += 1
    end

    false_plan = CompositeAlgorithm(
        LoopRunIfCounter,
        (RunIf(x -> x, Var(LoopRunIfFlag, :enabled)),),
        LoopRunIfFlag,
    )
    false_result = run(init(false_plan); repeats = 3)
    @test context(false_result)[LoopRunIfCounter].count == 0

    true_initialized = init(false_plan, Override(LoopRunIfFlag; enabled = true))
    true_result = run(true_initialized; repeats = 3)
    @test context(true_result)[LoopRunIfCounter].count == 3

    interval_plan = CompositeAlgorithm(
        LoopRunIfCounter,
        (RunIf(Interval(2), x -> x, Var(LoopRunIfFlag, :enabled)),),
        LoopRunIfFlag,
    )
    interval_result = run(init(interval_plan, Override(LoopRunIfFlag; enabled = true)); repeats = 3)
    @test context(interval_result)[LoopRunIfCounter].count == 1

    nested_plan = CompositeAlgorithm(
        CompositeAlgorithm(LoopRunIfCounter, (RunIf(x -> x, Var(LoopRunIfFlag, :enabled)),)),
        (1,),
        LoopRunIfFlag,
    )
    nested_result = run(init(nested_plan, Override(LoopRunIfFlag; enabled = true)); repeats = 2)
    @test context(nested_result)[LoopRunIfCounter].count == 2
end

# Defined at top level: defined inside a `@testset`, the plan allocates per step.
@StepAlgorithm function BootSensor(@managed(n = 0); reading = nothing)
    @update n += 1
    @update reading = Float64(n)
end
@StepAlgorithm function BootReader(reading, @managed(acc = 0.0))
    @update acc += reading
end

@testset "Bootstrap step keeps routed transients concretely typed" begin

    # Producer and consumer both run on step 1 and every 10 steps after it.
    plan = CompositeAlgorithm(BootSensor, BootReader, (Interval(10, :start), Interval(10, :start)), Route(BootSensor => BootReader, :reading))
    run(InlineProcess(plan; repeats = 100))
    small = InlineProcess(plan; repeats = 1_000)
    large = InlineProcess(plan; repeats = 101_000)
    allocs_small = @allocated run(small)
    allocs_large = @allocated run(large)
    @test allocs_large - allocs_small < 1_000
    @test context(large)[BootReader].acc == 10_100 * 10_101 / 2
end

@testset "Nested routines stay specialized (no per-step allocation)" begin
    for plan in (Routine(Routine(NestLin1, NestLin2, (1, 1)), NestLin3, (1, 1)),
                 Routine(Routine(Routine(NestLin1, NestLin2, (1, 1)), NestLin3, (1, 1)), NestLin4, (1, 1)),
                 Routine(CompositeAlgorithm(Routine(NestLin1, NestLin2, (1, 1)), NestLin3, (1, 1)), NestLin4, (1, 1)))
        run(InlineProcess(plan; repeats = 100))
        small = InlineProcess(plan; repeats = 1_000)
        large = InlineProcess(plan; repeats = 101_000)
        allocs_small = @allocated run(small)
        allocs_large = @allocated run(large)
        @test allocs_large - allocs_small < 1_000
        @test context(large)[NestLin1].x == 101_000
    end
end
