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

    context, plan = setup(plan_spec, Init(PipelineCounter; total = 10))
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
    two, two_plan = setup(two_spec, Init(PipelineCounter; total = 1), Init(PipelineOther; count = 2))
    two, _ = run(two_plan, two; repeats = 2, step = 1)
    @test (two[PipelineCounter].total, two[PipelineOther].count) == (3, 4)
    partial = reinit(two_plan, two, Init(PipelineCounter; total = 100))
    @test (partial[PipelineCounter].total, partial[PipelineOther].count) == (100, 4)
    partial = reinit(two_plan, partial, Init(PipelineCounter; total = 7), Override(PipelineCounter; total = 8))
    @test partial[PipelineCounter].total == 8
    partial = reinit(two_plan, partial, Override(PipelineOther; count = 50))
    @test (partial[PipelineCounter].total, partial[PipelineOther].count) == (8, 50)
    @test_throws ArgumentError reinit(two_spec, partial, Init(PipelineCounter; total = 1))

    overridden, _ = setup(plan_spec, Override(PipelineCounter; total = 5))
    @test overridden[PipelineCounter].total == 5
end
