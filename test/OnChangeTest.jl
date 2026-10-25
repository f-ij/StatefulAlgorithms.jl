using Test
using StatefulAlgorithms

@testset "OnChange runs its callback when a write changes the value" begin
    # `value` changes in every step; `fixed` is written back unchanged and never fires.
    @StepAlgorithm function OnChangeTarget(@managed(value = 1.0, fixed = 2.0))
        @update value = value + 1
        @update fixed = fixed
    end

    algo = resolve(CompositeAlgorithm(:target => OnChangeTarget(), (1,)))

    changes = Tuple{Float64, Float64}[]
    unchanged = Tuple{Float64, Float64}[]
    initialized = init(
        algo,
        Override(:target; value = OnChange(3.0, (old, new) -> push!(changes, (old, new))),
                          fixed = OnChange(2.0, (old, new) -> push!(unchanged, (old, new))));
        lifetime = Repeat(1),
    )
    context = StatefulAlgorithms.context(initialized)
    @test context.target.value isa OnChange{Float64}
    @test isempty(changes)                      # putting it in the context does not fire

    stepped = StatefulAlgorithms._step!(initialized, context)
    @test typeof(stepped) === typeof(context)   # the write keeps the wrapper and its type
    @test stepped.target.value isa OnChange{Float64}
    @test changes == [(3.0, 4.0)]

    stepped = StatefulAlgorithms._step!(initialized, stepped)
    @test changes == [(3.0, 4.0), (4.0, 5.0)]
    @test isempty(unchanged)
end

@testset "OnChange is read and shown as its value" begin
    seen = Float64[]
    @StepAlgorithm function OnChangeReader(@managed(value = 1.0))
        push!(seen, value)
        @update value = value * 2
    end

    fired = Ref(0)
    p = InlineProcess(resolve(CompositeAlgorithm(:reader => OnChangeReader(), (1,))),
                      Override(:reader; value = OnChange(1.0, (old, new) -> fired[] += 1)); repeats = 3)
    run(p)
    @test seen == [1.0, 2.0, 4.0]
    @test fired[] == 3
    @test StatefulAlgorithms.getcontext(p).reader.value isa OnChange{Float64}
end
