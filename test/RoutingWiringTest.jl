using Test
using StatefulAlgorithms

@testset "Routing wiring types" begin
    struct WiringSource <: ProcessAlgorithm end
    struct WiringTarget <: ProcessAlgorithm end
    struct WiringOther <: ProcessAlgorithm end

    @test StatefulAlgorithms.Route <: StatefulAlgorithms.AbstractWiring
    @test StatefulAlgorithms.Share <: StatefulAlgorithms.AbstractWiring
    @test StatefulAlgorithms.LocalPlanOption <: StatefulAlgorithms.AbstractWiring
    @test !(StatefulAlgorithms.Route <: StatefulAlgorithms.AbstractOption)
    @test !(StatefulAlgorithms.Share <: StatefulAlgorithms.AbstractOption)
    @test !(StatefulAlgorithms.LocalPlanOption <: StatefulAlgorithms.AbstractOption)
    @test !isdefined(StatefulAlgorithms, :StepRouting)
    @test !isdefined(StatefulAlgorithms, :SharedContext)
    @test !isdefined(StatefulAlgorithms, :SharedVars)

    empty_wiring = StatefulAlgorithms.Wiring()
    @test empty_wiring isa StatefulAlgorithms.Wiring{Tuple{}, Tuple{}}
    @test isempty(empty_wiring)

    resolved_route = Route(:source => :target, :value => :seen)
    @test StatefulAlgorithms.isresolved(resolved_route)
    @test StatefulAlgorithms.isresolved(typeof(resolved_route))
    @test typeof(resolved_route)() == resolved_route

    raw_route = Route(WiringSource => WiringTarget, :value)
    @test !StatefulAlgorithms.isresolved(raw_route)
    @test !StatefulAlgorithms.isresolved(typeof(raw_route))
    @test StatefulAlgorithms.getfrom(raw_route) === WiringSource
    @test StatefulAlgorithms.getto(raw_route) === WiringTarget

    resolved_share = Share(:source, :target)
    @test StatefulAlgorithms.isresolved(resolved_share)
    @test StatefulAlgorithms.isresolved(typeof(resolved_share))
    @test typeof(resolved_share)() == resolved_share

    raw_share = Share(WiringSource, WiringTarget)
    @test !StatefulAlgorithms.isresolved(raw_share)
    @test !StatefulAlgorithms.isresolved(typeof(raw_share))
    @test StatefulAlgorithms.get_firstalgo(raw_share) === WiringSource
    @test StatefulAlgorithms.get_secondalgo(raw_share) === WiringTarget

    route_a = Route{:a, :target, nothing, nothing, (:x,), (:value,), Nothing, Nothing}()
    route_b = Route{:b, :target, nothing, nothing, (:y,), (:value,), Nothing, Nothing}()
    share_a = Share{:a, :target, true, Nothing, Nothing}()
    merged = StatefulAlgorithms.merge_wiring(StatefulAlgorithms.Wiring((route_a,), ()), StatefulAlgorithms.Wiring((route_b,), ()))
    @test StatefulAlgorithms.routes(merged) == (route_b,)

    typed_wiring = StatefulAlgorithms.Wiring{Tuple{typeof(route_a)}, Tuple{typeof(share_a)}}()
    @test typed_wiring == StatefulAlgorithms.Wiring((route_a,), (share_a,))
    @test typeof(typed_wiring)() == typed_wiring

    grouped_wiring = NamedTuple{(:target,), Tuple{typeof(typed_wiring)}}
    typed_plan_wiring = StatefulAlgorithms.PlanWiring{grouped_wiring, Tuple{typeof(typed_wiring)}}()
    @test StatefulAlgorithms.global_wiring(typed_plan_wiring).target == typed_wiring
    @test StatefulAlgorithms.child_wiring(typed_plan_wiring) == (typed_wiring,)
    @test typeof(typed_plan_wiring)() == typed_plan_wiring
    @test StatefulAlgorithms.wiring_from_type(typeof(typed_plan_wiring)) == typed_plan_wiring

    plan = CompositeAlgorithm(
        WiringSource,
        WiringTarget,
        WiringOther,
        (1, 1, 1),
        Share(WiringSource, WiringTarget),
        Route(WiringSource => WiringOther, :value),
    )
    plan_wiring = StatefulAlgorithms.getwiring(plan)
    @test StatefulAlgorithms.global_wiring(plan_wiring) isa StatefulAlgorithms.Wiring
    @test length(StatefulAlgorithms.child_wiring(plan_wiring)) == 3
    @test all(x -> x isa StatefulAlgorithms.Wiring, StatefulAlgorithms.child_wiring(plan_wiring))

    resolved = resolve(plan)
    resolved_wiring = StatefulAlgorithms.getwiring(StatefulAlgorithms.getplan(resolved))
    @test StatefulAlgorithms.global_wiring(resolved_wiring) isa NamedTuple
    @test length(StatefulAlgorithms.child_wiring(resolved_wiring)) == 3

    all_resolved(w::StatefulAlgorithms.Wiring) =
        all(StatefulAlgorithms.isresolved, StatefulAlgorithms.routes(w)) &&
        all(StatefulAlgorithms.isresolved, StatefulAlgorithms.shares(w))
    all_resolved(w::StatefulAlgorithms.PlanWiring) =
        all(all_resolved, values(StatefulAlgorithms.global_wiring(w))) &&
        all(all_resolved, StatefulAlgorithms.child_wiring(w))

    @test all_resolved(resolved_wiring)
end
