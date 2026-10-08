using Test
using StatefulAlgorithms

struct ReplacementSourceState <: AlgoState end
struct ReplacementSourceAlgo <: ProcessAlgorithm end
struct ReplacementTargetAlgo <: ProcessAlgorithm end
struct ReplacementReadTargetAlgo <: ProcessAlgorithm end

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

function StatefulAlgorithms.init(::ReplacementSourceAlgo, context::C) where {C}
    return (; value = 3)
end

function StatefulAlgorithms.step!(::ReplacementSourceAlgo, context::C) where {C}
    return (; value = context.value)
end

function StatefulAlgorithms.init(::ReplacementTargetAlgo, context::C) where {C}
    return (; value = 100, seen = 0)
end

function StatefulAlgorithms.step!(::ReplacementTargetAlgo, context::C) where {C}
    return (; value = context.value + 1, seen = context.value)
end

function StatefulAlgorithms.init(::ReplacementReadTargetAlgo, context::C) where {C}
    return (; value = 100, seen = 0)
end

function StatefulAlgorithms.step!(::ReplacementReadTargetAlgo, context::C) where {C}
    return (; seen = context.value)
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

        @test context.target.value isa ReplacedVar
        @test context.source.value == 3

        stepped_context = StatefulAlgorithms._step!(initialized, context)

        @test stepped_context.source.value == 4
        @test stepped_context.target.value isa ReplacedVar
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
        @test stepped_context.target.value isa ReplacedVar
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
        @test context.target.value isa ReplacedVar

        stepped_context = StatefulAlgorithms._step!(initialized, context)
        @test stepped_context.source.value == 4
        @test stepped_context.target.seen == 3
    end
end

@testset "update_keys updates the keys of a plan's Replace, route and children" begin
    struct UKSource <: ProcessAlgorithm end
    StatefulAlgorithms.init(::UKSource, context) = (; x = 1.0)
    StatefulAlgorithms.step!(::UKSource, context) = (; x = context.x + 1)
    struct UKSink <: ProcessAlgorithm end
    StatefulAlgorithms.init(::UKSink, context) = (; seen = 0.0, y = 0.0)
    StatefulAlgorithms.step!(::UKSink, context) = (; seen = context.x)

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
    struct NRSource <: ProcessAlgorithm end
    StatefulAlgorithms.init(::NRSource, context) = (; x = 1.0)
    StatefulAlgorithms.step!(::NRSource, context) = (; x = context.x + 1)
    struct NRSink <: ProcessAlgorithm end
    StatefulAlgorithms.init(::NRSink, context) = (; seen = 0.0, y = 0.0)
    StatefulAlgorithms.step!(::NRSink, context) = (; seen = context.y)
    struct NROther <: ProcessAlgorithm end
    StatefulAlgorithms.init(::NROther, context) = (;)
    StatefulAlgorithms.step!(::NROther, context) = (;)

    inner = CompositeAlgorithm(NRSource, NRSink, (1, 1), Replace(NRSource => NRSink, :x => :y))
    outer = CompositeAlgorithm(inner, NROther, (1, 1))

    @test only(getoptions(resolve(outer))) isa Replace   # collected from the nested plan
    c = StatefulAlgorithms.context(run(outer; repeats = 3))
    @test c[NRSink].seen == c[NRSource].x == 4.0         # the sink's `y` is the source's `x`
end
