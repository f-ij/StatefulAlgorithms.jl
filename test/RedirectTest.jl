using Test
using StatefulAlgorithms

struct RedirectSourceState <: AlgoState end

struct RecursiveViewWrapper{T}
    value::T
end

"""Recursively expose the wrapped test value through the generic view hook."""
function StatefulAlgorithms.view_value(view::V, value::RecursiveViewWrapper{T}) where {T, V<:StatefulAlgorithms.SubContextView}
    return StatefulAlgorithms.view_value(view, getfield(value, :value))
end

function StatefulAlgorithms.init(::RedirectSourceState, context::C) where {C}
    return (; value = 3)
end

@StepAlgorithm function RedirectSourceAlgo(@managed(value = 3))
    @update value
end

@StepAlgorithm function RedirectTargetAlgo(@managed(value = 100, seen = 0))
    @update seen = value
    @update value = value + 1
end

@StepAlgorithm function RedirectReadTargetAlgo(@managed(value = 100, seen = 0))
    @update seen = value
end

@testset "Redirect variables" begin
    @testset "Generic view values unfold recursively" begin
        algo = resolve(CompositeAlgorithm(
            :target => RedirectReadTargetAlgo(),
            (1,),
        ))

        initialized = init(algo, Override(:target; value = RecursiveViewWrapper(RecursiveViewWrapper(5))); lifetime = Repeat(1))
        stepped_context = StatefulAlgorithms._step!(initialized, StatefulAlgorithms.context(initialized))

        @test stepped_context.target.seen == 5
        @test stepped_context.target.value isa RecursiveViewWrapper
    end

    @testset "Redirect reads and writes through source location" begin
        algo = resolve(CompositeAlgorithm(
            :target => RedirectTargetAlgo(),
            (1,),
            :source => RedirectSourceState(),
            Redirect(:source => :target, :value),
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

    @testset "Redirect composes with source-side view wrappers" begin
        algo = resolve(CompositeAlgorithm(
            :target => RedirectReadTargetAlgo(),
            (1,),
            :source => RedirectSourceState(),
            Redirect(:source => :target, :value),
        ))

        initialized = init(algo, Override(:source; value = RecursiveViewWrapper(RecursiveViewWrapper(8))); lifetime = Repeat(1))
        stepped_context = StatefulAlgorithms._step!(initialized, StatefulAlgorithms.context(initialized))

        @test stepped_context.target.seen == 8
        @test stepped_context[Var(:target, :value)] === stepped_context.source.value
    end

    @testset "A Redirect cycle is an error when the redirects are applied" begin
        cycle = resolve(CompositeAlgorithm(
            :target => RedirectReadTargetAlgo(),
            (1,),
            :source => RedirectSourceState(),
            Redirect(:source => :target, :value),
            Redirect(:target => :source, :value),
        ))
        @test_throws "Redirect makes a cycle" init(cycle; lifetime = Repeat(1))

        to_itself = resolve(CompositeAlgorithm(
            :target => RedirectReadTargetAlgo(),
            (1,),
            Redirect(:target => :target, :value),
        ))
        @test_throws "Redirect makes a cycle" init(to_itself; lifetime = Repeat(1))
    end

    @testset "DSL @redirect lowers to root redirect option" begin
        algo = @CompositeAlgorithm begin
            @alias source = RedirectSourceAlgo
            @alias target = RedirectTargetAlgo
            source()
            target()
            @redirect source.value => target.value
        end

        resolved = resolve(algo)
        @test only(getoptions(resolved, Redirect)) isa Redirect

        initialized = init(resolved; lifetime = Repeat(1))
        context = StatefulAlgorithms.context(initialized)
        @test context[Var(:target, :value)] == 3

        stepped_context = StatefulAlgorithms._step!(initialized, context)
        @test stepped_context.source.value == 4
        @test stepped_context.target.seen == 3
    end
end

@testset "update_keys updates the keys of a plan's Redirect, route and children" begin
    @StepAlgorithm function UKSource(@managed(x = 1.0))
        @update x += 1
    end
    @StepAlgorithm function UKSink(x, @managed(seen = 0.0, y = 0.0))
        @update seen = x
    end

    plan = CompositeAlgorithm(UKSource, UKSink, (1, 1),
        StatefulAlgorithms.LocalPlanOption(UKSink, Route(UKSource => UKSink, :x)),
        Redirect(UKSource => UKSink, :x => :y))
    updated = StatefulAlgorithms.update_keys(plan, StatefulAlgorithms.getregistry(resolve(plan)))

    redirect = only(getoptions(updated))
    @test getkey(StatefulAlgorithms.getfrom(redirect)) == :UKSource_1
    @test getkey(StatefulAlgorithms.getto(redirect)) == :UKSink_1
    @test map(getkey, StatefulAlgorithms.getalgos(updated)) == (:UKSource_1, :UKSink_1)
    # The route still belongs to the sink
    @test map(w -> length(StatefulAlgorithms.routes(w)), StatefulAlgorithms.child_wiring(StatefulAlgorithms.getwiring(updated))) == (0, 1)
end

@testset "A Redirect declared in a nested plan applies to the whole run" begin
    @StepAlgorithm function NRSource(@managed(x = 1.0))
        @update x += 1
    end
    @StepAlgorithm function NRSink(@managed(seen = 0.0, y = 0.0))
        @update seen = y
    end
    @StepAlgorithm function NROther()
        return
    end

    inner = CompositeAlgorithm(NRSource, NRSink, (1, 1), Redirect(NRSource => NRSink, :x => :y))
    outer = CompositeAlgorithm(inner, NROther, (1, 1))

    @test only(getoptions(resolve(outer))) isa Redirect   # collected from the nested plan
    # A nested plan given a name (`insert` allows it) is a wrapper, not a plan, until `resolve` unwraps it.
    named = insert(CompositeAlgorithm(NROther, (1,)), 2, StatefulAlgorithms.IdentifiableAlgo(inner, :named))
    @test only(getoptions(resolve(named))) isa Redirect
    c = StatefulAlgorithms.context(run(outer; repeats = 3))
    @test c[NRSink].seen == c[NRSource].x == 4.0         # the sink's `y` is the source's `x`
end
