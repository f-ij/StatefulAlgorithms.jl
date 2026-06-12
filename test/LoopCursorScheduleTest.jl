using Test
using StatefulAlgorithms

@testset "Loop cursors and conditional schedules" begin
    struct LoopCursorIntervalCounter <: ProcessAlgorithm end
    struct LoopCursorYieldCounter <: ProcessAlgorithm end

    StatefulAlgorithms.init(::LoopCursorIntervalCounter, context) = (; count = 0)
    StatefulAlgorithms.step!(::LoopCursorIntervalCounter, context) = (; count = context.count + 1)
    StatefulAlgorithms.init(::LoopCursorYieldCounter, context) = (; count = 0)
    StatefulAlgorithms.step!(::LoopCursorYieldCounter, context) = (sleep(0.001); (; count = context.count + 1))

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
    @test StatefulAlgorithms.resume_idxs(pausable_cursor) isa StatefulAlgorithms.MVector

    long_routine = init(Routine(LoopCursorYieldCounter, (10^8,)))
    paused = Process(long_routine; lifetime = Indefinite())
    run(paused)
    sleep(0.01)
    pause(paused)
    wait(paused)
    @test paused.loop_cursor isa StatefulAlgorithms.PausableRoutineCursor
    @test !isempty(StatefulAlgorithms.resume_idxs(paused.loop_cursor))
    close(paused)
    @test isnothing(paused.loop_cursor)

    struct LoopRunIfFlag <: ProcessState end
    struct LoopRunIfCounter <: ProcessAlgorithm end

    StatefulAlgorithms.init(::LoopRunIfFlag, context) = (; enabled = false)
    StatefulAlgorithms.init(::LoopRunIfCounter, context) = (; count = 0)
    StatefulAlgorithms.step!(::LoopRunIfCounter, context) = (; count = context.count + 1)

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
