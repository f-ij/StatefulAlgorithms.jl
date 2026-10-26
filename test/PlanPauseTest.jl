using Test
using StatefulAlgorithms
const SApp = StatefulAlgorithms

# One `Plan` with interval and repeat entries, its default lifetime, and pausing in the middle of a step.

@StepAlgorithm function PPCountA(@managed(a = 0))
    @update a += 1
end
@StepAlgorithm function PPCountC(@managed(c = 0))
    @update c += 1
end
# Slow, so that a pause lands while its repeats run.
@StepAlgorithm function PPSlowB(@managed(b = 0))
    sleep(0.002)
    @update b += 1
end
@StepAlgorithm function PPProducer(@managed(n = 0))
    @update n += 1
    return 10 * n
end
@StepAlgorithm function PPSlowConsumer(y, @managed(total = 0, calls = 0))
    sleep(0.002)
    @update total += y
    @update calls += 1
end

"""Run `p`, pause it after `delay` seconds, check that it paused, then run it to the end."""
function pp_pause_and_finish!(p; delay = 0.08)
    run(p)
    sleep(delay)
    pause(p)
    wait(p)
    paused_in_step = SApp.is_paused_in_step(p.loop_cursor)
    run(p)
    wait(p)
    return paused_in_step
end

@testset "Plan: interval and repeat entries in one plan" begin
    mixed = CompositeAlgorithm(PPCountA, PPCountC, (2, Repeat(3)))
    @test mixed isa Plan
    @test SApp.getschedule(mixed) == (Interval(2), Repeat(3))
    result = run(init(mixed); repeats = 4)
    @test context(result)[PPCountA].a == 2
    @test context(result)[PPCountC].c == 12

    routine = Routine(PPCountA, PPCountC, (2, Interval(1)))
    @test SApp.getschedule(routine) == (Repeat(2), Interval(1))
    result = run(init(routine); repeats = 3)
    @test context(result)[PPCountA].a == 6
    @test context(result)[PPCountC].c == 3

    # A nested plan of intervals is flattened into a parent's interval entry, not into a repeat.
    flat = CompositeAlgorithm(CompositeAlgorithm(PPCountA, PPCountC, (1, 2)), (3,))
    @test length(getalgos(flat)) == 2
    @test SApp.getschedule(flat) == (Interval(3), Interval(6))
    nested = CompositeAlgorithm(CompositeAlgorithm(PPCountA, PPCountC, (1, 2)), (Repeat(3),))
    @test length(getalgos(nested)) == 1
    @test getalgos(nested)[1] isa Plan
end

@testset "Plan: default lifetime" begin
    @test StatefulAlgorithms.find_default_lifetime(getoptions(Routine(PPCountA, (2,)))) == Repeat(1)
    @test isnothing(StatefulAlgorithms.find_default_lifetime(getoptions(CompositeAlgorithm(PPCountA))))
    # A process of a routine runs one step unless given another lifetime.
    p = Process(init(Routine(PPCountA, (2,))))
    run(p); wait(p)
    @test context(p)[PPCountA].a == 2
    @test StatefulAlgorithms.normalize_process_lifetime(CompositeAlgorithm(PPCountA), nothing) isa Indefinite
end

@testset "Plan: a paused step resumes where it stopped" begin
    # Each step: A once, B 100 times, C 100 times. A pause in B's repeats: the next run continues B there, C does not
    # run before, and A does not run again.
    p = Process(init(Routine(PPCountA, PPSlowB, PPCountC, (1, 100, 100))); lifetime = Repeat(2))
    @test pp_pause_and_finish!(p)
    c = context(p)
    @test (c[PPCountA].a, c[PPSlowB].b, c[PPCountC].c) == (2, 200, 200)

    # Indefinite lifetime: a pause in the first step, then a close after it is finished.
    p = Process(init(Routine(PPCountA, PPSlowB, (1, 100))); lifetime = Until(x -> x >= 1, Var(PPCountA, :a)))
    run(p); sleep(0.08); pause(p); wait(p)
    @test SApp.is_paused_in_step(p.loop_cursor)
    run(p); wait(p)
    @test (context(p)[PPCountA].a, context(p)[PPSlowB].b) == (1, 100)
end

@testset "Plan: a resumed step keeps the returns captured before the pause" begin
    plan = @Routine begin
        y = PPProducer()
        @repeat 100 PPSlowConsumer(y)
    end
    p = Process(init(plan); lifetime = Repeat(2))
    @test pp_pause_and_finish!(p)
    c = context(p)
    @test c[PPProducer].n == 2
    @test c[PPSlowConsumer].calls == 200
    @test c[PPSlowConsumer].total == 100 * 10 + 100 * 20
end

@testset "Plan: a pause in a nested plan resumes in it" begin
    # A routine run on an interval entry: the step stops in the nested routine; the composite's next child waits.
    p = Process(init(CompositeAlgorithm(Routine(PPSlowB, (100,)), PPCountC)); lifetime = Repeat(2))
    @test pp_pause_and_finish!(p)
    @test (context(p)[PPSlowB].b, context(p)[PPCountC].c) == (200, 2)

    # A routine repeated by a routine: the outer repeat that was interrupted is finished, not skipped.
    p = Process(init(Routine(Routine(PPSlowB, PPCountA, (50, 1)), PPCountC, (2, 1))); lifetime = Repeat(2))
    @test pp_pause_and_finish!(p)
    c = context(p)
    @test (c[PPSlowB].b, c[PPCountA].a, c[PPCountC].c) == (200, 4, 2)

    # Two pauses in one run.
    p = Process(init(Routine(PPCountA, PPSlowB, PPCountC, (1, 100, 100))); lifetime = Repeat(2))
    run(p); sleep(0.05); pause(p); wait(p)
    run(p); sleep(0.05); pause(p); wait(p)
    run(p); wait(p)
    c = context(p)
    @test (c[PPCountA].a, c[PPSlowB].b, c[PPCountC].c) == (2, 200, 200)
end

@testset "Plan: cursors" begin
    composite = CompositeAlgorithm(PPCountA, (2,))
    routine = Routine(PPCountA, (3,))
    @test SApp.loop_cursor(composite, Val(true)) isa SApp.PlanCursor{Base.RefValue{Int}, Nothing}
    @test SApp.loop_cursor(routine, Val(false)) isa SApp.PlanCursor{Nothing, Nothing}
    @test SApp.loop_cursor(routine, Val(true)) isa SApp.PlanCursor{Nothing, SApp.PauseRecord}
    @test !SApp.is_paused_in_step(SApp.loop_cursor(routine, Val(true)))
end
