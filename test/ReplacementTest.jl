using Test
using StatefulAlgorithms

struct ReplacementSourceState <: AlgoState end

struct RecursiveViewWrapper{T}
    value::T
end

"""Recursively expose the wrapped test value through the generic view hook."""
function StatefulAlgorithms.subcontext_view_value(value::RecursiveViewWrapper{T}, view::V) where {T, V<:StatefulAlgorithms.SubContextView}
    return StatefulAlgorithms.subcontext_view_value(getfield(value, :value), view)
end

function StatefulAlgorithms.init(::ReplacementSourceState, context::C) where {C}
    return (; value = 3)
end

@StepAlgorithm function ReplacementSourceAlgo(@managed(value = 3))
    @update value
end

@StepAlgorithm function ReplacementTargetAlgo(@managed(value = 100, seen = 0))
    @update seen = value
    @update value = value + 1
end

@StepAlgorithm function ReplacementReadTargetAlgo(@managed(value = 100, seen = 0))
    @update seen = value
end

@testset "Replacement variables" begin
    @testset "Generic view values unfold recursively" begin
        algo = resolve(CompositeAlgorithm(
            :target => ReplacementReadTargetAlgo(),
            (1,),
        ))

        initialized = init(algo, Override(:target; value = RecursiveViewWrapper(RecursiveViewWrapper(5))); lifetime = Repeat(1))
        stepped_context = StatefulAlgorithms._step!(initialized, StatefulAlgorithms.context(initialized))

        @test stepped_context.target.seen == 5
        @test stepped_context.target.value isa RecursiveViewWrapper
    end

    @testset "Replacement reads and writes through source location" begin
        algo = resolve(CompositeAlgorithm(
            :target => ReplacementTargetAlgo(),
            (1,),
            :source => ReplacementSourceState(),
            Replace(:source => :target, :value),
        ))

        initialized = init(algo; lifetime = Repeat(1))
        context = StatefulAlgorithms.context(initialized)

        @test context[Var(:target, :value)] == 3
        @test context.source.value == 3

        stepped_context = StatefulAlgorithms._step!(initialized, context)

        @test stepped_context.source.value == 4
        @test stepped_context[Var(:target, :value)] == 4
        @test stepped_context.target.seen == 3
    end

    @testset "Replacement composes with source-side view wrappers" begin
        algo = resolve(CompositeAlgorithm(
            :target => ReplacementReadTargetAlgo(),
            (1,),
            :source => ReplacementSourceState(),
            Replace(:source => :target, :value),
        ))

        initialized = init(algo, Override(:source; value = RecursiveViewWrapper(RecursiveViewWrapper(8))); lifetime = Repeat(1))
        stepped_context = StatefulAlgorithms._step!(initialized, StatefulAlgorithms.context(initialized))

        @test stepped_context.target.seen == 8
        @test stepped_context[Var(:target, :value)] === stepped_context.source.value
    end

    @testset "DSL @replace lowers to root replacement option" begin
        algo = @CompositeAlgorithm begin
            @alias source = ReplacementSourceAlgo
            @alias target = ReplacementTargetAlgo
            source()
            target()
            @replace source.value => target.value
        end

        resolved = resolve(algo)
        @test only(getoptions(resolved, Replace)) isa Replace

        initialized = init(resolved; lifetime = Repeat(1))
        context = StatefulAlgorithms.context(initialized)
        @test context[Var(:target, :value)] == 3

        stepped_context = StatefulAlgorithms._step!(initialized, context)
        @test stepped_context.source.value == 4
        @test stepped_context.target.seen == 3
    end
end

@testset "update_keys updates the keys of a plan's Replace, route and children" begin
    @StepAlgorithm function UKSource(@managed(x = 1.0))
        @update x += 1
    end
    @StepAlgorithm function UKSink(x, @managed(seen = 0.0, y = 0.0))
        @update seen = x
    end

    plan = CompositeAlgorithm(UKSource, UKSink, (1, 1),
        StatefulAlgorithms.LocalPlanOption(UKSink, Route(UKSource => UKSink, :x)),
        Replace(UKSource => UKSink, :x => :y))
    updated = StatefulAlgorithms.update_keys(plan, StatefulAlgorithms.getregistry(resolve(plan)))

    replace = only(getoptions(updated))
    @test getkey(StatefulAlgorithms.getfrom(replace)) == :UKSource_1
    @test getkey(StatefulAlgorithms.getto(replace)) == :UKSink_1
    @test map(getkey, StatefulAlgorithms.getalgos(updated)) == (:UKSource_1, :UKSink_1)
    # The route still belongs to the sink
    @test map(w -> length(StatefulAlgorithms.routes(w)), StatefulAlgorithms.child_wiring(StatefulAlgorithms.getwiring(updated))) == (0, 1)
end

@testset "A Replace declared in a nested plan applies to the whole run" begin
    @StepAlgorithm function NRSource(@managed(x = 1.0))
        @update x += 1
    end
    @StepAlgorithm function NRSink(@managed(seen = 0.0, y = 0.0))
        @update seen = y
    end
    @StepAlgorithm function NROther()
        return
    end

    inner = CompositeAlgorithm(NRSource, NRSink, (1, 1), Replace(NRSource => NRSink, :x => :y))
    outer = CompositeAlgorithm(inner, NROther, (1, 1))

    @test only(getoptions(resolve(outer))) isa Replace   # collected from the nested plan
    c = StatefulAlgorithms.context(run(outer; repeats = 3))
    @test c[NRSink].seen == c[NRSource].x == 4.0         # the sink's `y` is the source's `x`
end
