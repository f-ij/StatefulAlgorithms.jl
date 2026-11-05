using Test
using StatefulAlgorithms

@StepAlgorithm function PipelineCounter(step, @managed(total = total); @init((; total = 0)))
    @update total += step
end

@StepAlgorithm function PipelineOther(@managed(count = count); @init((; count = 0)))
    @update count += 1
end

@testset "User pipeline: setup, run, cleanup" begin
    plan_spec = @CompositeAlgorithm begin
        @input step
        PipelineCounter(step)
    end

    context, plan = setup(plan_spec, InitArgs(PipelineCounter; total = 10))
    @test StatefulAlgorithms.isresolved(plan)
    @test !hasfield(typeof(plan), :context)   # the plan holds no data
    @test context[PipelineCounter].total == 10

    context, _ = run(plan, context; repeats = 3, step = 2)
    @test context[PipelineCounter].total == 16
    context, _ = run(plan, context; repeats = 1, step = 4)
    @test context[PipelineCounter].total == 20

    @test_throws ArgumentError run(plan_spec, context; step = 1)
    @test cleanup(plan, context) isa StatefulAlgorithms.ProcessContext

    two_spec = @CompositeAlgorithm begin
        @input step
        PipelineCounter(step)
        PipelineOther()
    end
    two, two_plan = setup(two_spec, InitArgs(PipelineCounter; total = 1), InitArgs(PipelineOther; count = 2))
    two, _ = run(two_plan, two; repeats = 2, step = 1)
    @test (two[PipelineCounter].total, two[PipelineOther].count) == (3, 4)
    # `Only` picks which `init` runs; the rest of the context is kept.
    partial = init(two_plan, two, Only(PipelineCounter), InitArgs(PipelineCounter; total = 100))
    @test (partial[PipelineCounter].total, partial[PipelineOther].count) == (100, 4)
    partial = init(two_plan, partial, Only(PipelineCounter), InitArgs(PipelineCounter; total = 7), Override(PipelineCounter; total = 8))
    @test partial[PipelineCounter].total == 8
    # An `Override` for a target whose `init` does not run only sets its values.
    partial = init(two_plan, partial, Only(PipelineCounter), Override(PipelineOther; count = 50))
    @test (partial[PipelineCounter].total, partial[PipelineOther].count) == (8, 50)
    # `Only(A)` without `InitArgs` runs A's `init` on its current values.
    partial = init(two_plan, partial, Only(PipelineOther))
    @test (partial[PipelineCounter].total, partial[PipelineOther].count) == (8, 50)
    # Without `Only` every `init` runs, on the given context.
    full = init(two_plan, partial, InitArgs(PipelineOther; count = 0))
    @test (full[PipelineCounter].total, full[PipelineOther].count) == (8, 0)
    # `InitArgs(; ...)` (= `InitArgs(ToAll(); ...)`) with an `Only` goes to the `Only` targets alone.
    partial = init(two_plan, full, Only(PipelineCounter), InitArgs(; total = 1, count = 9))
    @test (partial[PipelineCounter].total, partial[PipelineOther].count) == (1, 0)

    @test_throws ArgumentError init(two_spec, partial, Only(PipelineCounter), InitArgs(PipelineCounter; total = 1))
    @test_throws ArgumentError init(two_plan, partial, Only(PipelineCounter), InitArgs(PipelineOther; count = 1))
    @test_throws ArgumentError init(two_plan, partial, Only(PipelineCounter), Only(PipelineOther))
    @test_throws ArgumentError setup(two_spec, Only(PipelineCounter))
    @test_throws ArgumentError Only()

    # The list form: `InitArgs(A => (; ...), B => (; ...))`.
    listed, _ = setup(two_spec, InitArgs(PipelineCounter => (; total = 3), PipelineOther => (; count = 5)))
    @test (listed[PipelineCounter].total, listed[PipelineOther].count) == (3, 5)
    @test InitArgs(PipelineCounter => (; total = 3)) isa StatefulAlgorithms.InitArgsList
    @test InitArgs(:a => (; x = 1), :b => (; y = 2)) isa StatefulAlgorithms.InitArgsList
    @test InitArgs(PipelineCounter, :total => (; x = 1)) isa InitArgs

    overridden, _ = setup(plan_spec, Override(PipelineCounter; total = 5))
    @test overridden[PipelineCounter].total == 5
end

@testset "init! on Process/TimedProcess, init on InlineProcess: full and Only, the merged specs kept" begin
    plan_spec = @CompositeAlgorithm begin
        @input step
        PipelineCounter(step)
        PipelineOther()
    end
    # An InlineProcess has `init(ip, ...)`, returning a new process (its specs and context are typed); the others
    # `init!(p, ...)`, returning `p`. Both keep the merged specs.
    initialize(p, specs...) = p isa InlineProcess ? init(p, specs...) : init!(p, specs...)
    for make in (spec -> Process(spec, InitArgs(PipelineCounter; total = 1), InitArgs(PipelineOther; count = 2); repeats = 1),
                 spec -> InlineProcess(spec, InitArgs(PipelineCounter; total = 1), InitArgs(PipelineOther; count = 2); repeats = 1),
                 spec -> TimedProcess(spec, InitArgs(PipelineCounter; total = 1), InitArgs(PipelineOther; count = 2); repeats = 1, interval = 0.01))
        p = make(plan_spec)
        state(p) = (getcontext(p)[PipelineCounter].total, getcontext(p)[PipelineOther].count)
        @test state(p) == (1, 2)

        # Only: A's `init` runs on the current state, the rest is kept.
        p1 = initialize(p, Only(PipelineCounter), InitArgs(PipelineCounter; total = 40))
        @test (p1 === p) == !(p isa InlineProcess)
        @test state(p1) == (40, 2)
        p isa InlineProcess && @test state(p) == (1, 2)   # the old InlineProcess is left as it was

        # Full: every `init` from the stored specs with the new ones merged over them.
        p2 = initialize(p1, InitArgs(PipelineOther; count = 7))
        @test state(p2) == (40, 7)
        p3 = initialize(p2)
        @test state(p3) == (40, 7)
        @test length(StatefulAlgorithms.getspecs(p3)) == 2

        last_state = state(p3)
        @test_throws ArgumentError initialize(p3, Only(PipelineCounter), InitArgs(PipelineOther; count = 1))
        @test state(p3) == last_state
        p isa InlineProcess || close(p)
    end
    @test !hasmethod(init!, Tuple{InlineProcess})
end
