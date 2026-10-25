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

@testset "OnChange with a condition on the old and the new value" begin
    @StepAlgorithm function OnChangeCounter(@managed(count = 0))
        @update count = count + 1
    end

    # Fires only when the count crosses a multiple of 3.
    crossed = Tuple{Int, Int}[]
    p = InlineProcess(resolve(CompositeAlgorithm(:counter => OnChangeCounter(), (1,))),
                      Override(:counter; count = OnChange(0, (old, new) -> push!(crossed, (old, new)), (old, new) -> new % 3 == 0));
                      repeats = 7)
    run(p)
    @test crossed == [(2, 3), (5, 6)]
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

@testset "An AfterMerge in a write's answer runs after the write, and keeps the write" begin
    # A wrapper whose write answers an `AfterMerge` before its `DirectWrite`: the write is still merged, and the
    # `AfterMerge` runs after `write_value` answered.
    order = Symbol[]
    struct AfterMergeProbe{T}
        value::T
    end
    StatefulAlgorithms.read_value(reader::R, p::AfterMergeProbe) where {R<:StatefulAlgorithms.AbstractContext} =
        StatefulAlgorithms.DirectRead(p.value)
    function StatefulAlgorithms.write_value(view::V, p::AfterMergeProbe{T}, request::StatefulAlgorithms.StoreInto{L}) where {V<:StatefulAlgorithms.SubContextView, T, L}
        push!(order, :write)
        return (StatefulAlgorithms.AfterMerge(() -> push!(order, :after), ()),
                StatefulAlgorithms.DirectWrite{L}(AfterMergeProbe(convert(T, request.value))))
    end

    @StepAlgorithm function AfterMergeTarget(@managed(value = 1.0))
        @update value = value + 1
    end
    algo = resolve(CompositeAlgorithm(:target => AfterMergeTarget(), (1,)))
    initialized = init(algo, Override(:target; value = AfterMergeProbe(1.0)); lifetime = Repeat(1))
    stepped = StatefulAlgorithms._step!(initialized, StatefulAlgorithms.context(initialized))
    @test stepped.target.value == AfterMergeProbe(2.0)   # the `AfterMerge` before the `DirectWrite` does not drop it
    @test order == [:write, :after]
end
