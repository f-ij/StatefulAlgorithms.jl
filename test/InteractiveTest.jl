using Test
using StatefulAlgorithms

@testset "Interactive lifecycle variables" begin
    # `value` is stored as an InteractiveVar, but the algorithm sees its value.
    @StepAlgorithm function InitTimeInteractiveTarget(@managed(value = 1.0, seen = 0.0))
        @update seen = value + 2
        @update value = value + 1
    end

    algo = resolve(CompositeAlgorithm(
        :target => InitTimeInteractiveTarget(),
        (1,),
    ))

    initialized = init(
        algo,
        Override(:target; value = 3.0),
        Interactive(:target, :value);
        lifetime = Repeat(1),
    )
    context = StatefulAlgorithms.context(initialized)

    @test context.target.value isa InteractiveVar{Float64}
    @test context.target.value[] == 3.0

    stepped_context = StatefulAlgorithms._step!(initialized, context)
    @test stepped_context.target.value isa InteractiveVar{Float64}
    @test stepped_context.target.value[] == 4.0
    @test stepped_context.target.seen == 5.0

    stepped_context.target.value[] = 10
    stepped_context = StatefulAlgorithms._step!(initialized, stepped_context)
    @test stepped_context.target.value[] == 11.0
    @test stepped_context.target.seen == 12.0

    replayed = init(initialized; lifetime = Repeat(1))
    @test StatefulAlgorithms.context(replayed).target.value isa InteractiveVar{Float64}
    @test StatefulAlgorithms.context(replayed).target.value[] == 3.0
end
