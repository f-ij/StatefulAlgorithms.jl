using Test
using StatefulAlgorithms

@StepAlgorithm function PipelineCounter(step, @managed(total = total); @init((; total = 0)))
    @update total += step
end

@testset "User pipeline: setup, run, cleanup" begin
    plan_spec = @CompositeAlgorithm begin
        @input step
        PipelineCounter(step)
    end

    context, plan = setup(plan_spec, Init(PipelineCounter; total = 10))
    @test StatefulAlgorithms.isresolved(plan)
    @test isnothing(StatefulAlgorithms.getpersistentcontext(plan))
    @test context[PipelineCounter].total == 10

    context, _ = run(plan, context; repeats = 3, step = 2)
    @test context[PipelineCounter].total == 16
    context, _ = run(plan, context; repeats = 1, step = 4)
    @test context[PipelineCounter].total == 20

    @test_throws ArgumentError run(plan_spec, context; step = 1)
    @test cleanup(plan, context) isa StatefulAlgorithms.ProcessContext

    overridden, _ = setup(plan_spec, Override(PipelineCounter; total = 5))
    @test overridden[PipelineCounter].total == 5
end
