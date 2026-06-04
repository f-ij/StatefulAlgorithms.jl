using Test
using StatefulAlgorithms

@testset "Loop algorithm materialization" begin
    struct PrepSource <: ProcessAlgorithm end
    struct PrepTarget <: ProcessAlgorithm end
    struct PrepOther <: ProcessAlgorithm end

    algo = CompositeAlgorithm(
        PrepSource,
        PrepTarget,
        PrepOther,
        (1, 1, 1),
        Share(PrepSource, PrepTarget),
        Route(PrepSource => PrepOther, :value => :target),
    )

    @test length(StatefulAlgorithms.getoptions(algo, StatefulAlgorithms.Route)) == 1
    @test algo isa StatefulAlgorithms.CompositeAlgorithm
    @test StatefulAlgorithms.getplan(algo) isa StatefulAlgorithms.CompositeAlgorithm
    @test length(StatefulAlgorithms.getoptions(StatefulAlgorithms.getplan(algo), StatefulAlgorithms.Route)) == 1

    resolved = StatefulAlgorithms.resolve(algo)
    registry = StatefulAlgorithms.getregistry(resolved)

    source_name = StatefulAlgorithms.static_findkey(registry, PrepSource)
    target_name = StatefulAlgorithms.static_findkey(registry, PrepTarget)
    other_name = StatefulAlgorithms.static_findkey(registry, PrepOther)

    @test resolved isa StatefulAlgorithms.LoopAlgorithm
    @test StatefulAlgorithms.getplan(resolved) isa StatefulAlgorithms.CompositeAlgorithm
    @test StatefulAlgorithms.isresolved(resolved)
    @test all(child -> !(child isa StatefulAlgorithms.AbstractIdentifiableAlgo), StatefulAlgorithms.getalgos(resolved))
    @test all(entry -> entry isa StatefulAlgorithms.AbstractIdentifiableAlgo, StatefulAlgorithms.all_algos(registry))
    @test length(StatefulAlgorithms.getoptions(StatefulAlgorithms.getplan(resolved), StatefulAlgorithms.Route)) == 1
    @test length(StatefulAlgorithms.child_wiring(StatefulAlgorithms.getwiring(StatefulAlgorithms.getplan(resolved)))) == length(StatefulAlgorithms.getalgos(resolved))
    @test !isnothing(source_name)
    @test !isnothing(target_name)
    @test !isnothing(other_name)
    @test isempty(StatefulAlgorithms.getoptions(resolved, StatefulAlgorithms.Route))

    sharedcontexts, sharedvars = StatefulAlgorithms._resolve_options(resolved)
    @test StatefulAlgorithms.contextname(only(sharedcontexts[source_name])) == target_name
    @test StatefulAlgorithms.contextname(only(sharedcontexts[target_name])) == source_name

    @test haskey(sharedvars, other_name)
    @test length(sharedvars[other_name]) == 1
    @test StatefulAlgorithms.get_fromname(only(sharedvars[other_name])) == source_name

    initialized = StatefulAlgorithms.init(algo)
    reinitialized = StatefulAlgorithms.init(initialized)
    @test typeof(StatefulAlgorithms.getplan(initialized)) === typeof(StatefulAlgorithms.getplan(reinitialized))
    @test StatefulAlgorithms.getplan(initialized) === StatefulAlgorithms.getplan(reinitialized)

    routine = Routine(algo, PrepOther, (2, 3))
    resolved_routine = StatefulAlgorithms.resolve(routine)
    nested_comp = first(StatefulAlgorithms.getalgos(resolved_routine))

    @test resolved_routine isa StatefulAlgorithms.LoopAlgorithm
    @test StatefulAlgorithms.getplan(resolved_routine) isa StatefulAlgorithms.Routine
    @test StatefulAlgorithms.isresolved(resolved_routine)
    @test nested_comp isa StatefulAlgorithms.CompositeAlgorithm
    @test all(child -> !(child isa StatefulAlgorithms.AbstractIdentifiableAlgo), StatefulAlgorithms.getalgos(resolved_routine))
    @test all(child -> !(child isa StatefulAlgorithms.AbstractIdentifiableAlgo), StatefulAlgorithms.getalgos(nested_comp))
    @test all(StatefulAlgorithms.plan_child_namespace(nested_comp, i) != Symbol() for i in eachindex(StatefulAlgorithms.getalgos(nested_comp)))
    routine_wiring = StatefulAlgorithms.getwiring(StatefulAlgorithms.getplan(resolved_routine))
    nested_plan_wiring = getfield(StatefulAlgorithms.child_wiring(routine_wiring), 1)
    nested_wiring = StatefulAlgorithms.child_wiring(nested_plan_wiring)
    @test length(StatefulAlgorithms.child_wiring(routine_wiring)) == length(StatefulAlgorithms.getalgos(resolved_routine))
    @test length(nested_wiring) == length(StatefulAlgorithms.getalgos(nested_comp))
    @test length(StatefulAlgorithms.shares(nested_wiring[2])) == 1
    @test length(StatefulAlgorithms.routes(nested_wiring[3])) == 1

    threaded = ThreadedCompositeAlgorithm(PrepSource, PrepTarget, (1, 1))
    @test threaded isa StatefulAlgorithms.ThreadedCompositeAlgorithm
    @test !StatefulAlgorithms.isresolved(threaded)
    @test StatefulAlgorithms.intervals(threaded) == (StatefulAlgorithms.Interval(1), StatefulAlgorithms.Interval(1))

    algo1 = CompositeAlgorithm(
        PrepSource,
        (1,),
        Share(PrepSource, PrepTarget),
        Route(PrepSource => PrepOther, :value => :target),
    )
    algo2 = CompositeAlgorithm(
        PrepTarget,
        PrepOther,
        (1, 1),
    )

    resolved1, resolved2 = StatefulAlgorithms.resolve(algo1, algo2)

    @test StatefulAlgorithms.isresolved(resolved1)
    @test StatefulAlgorithms.isresolved(resolved2)
    @test StatefulAlgorithms.getregistry(resolved1) === StatefulAlgorithms.getregistry(resolved2)

    shared_registry = StatefulAlgorithms.getregistry(resolved1)
    source_name = StatefulAlgorithms.static_findkey(shared_registry, PrepSource)
    target_name = StatefulAlgorithms.static_findkey(shared_registry, PrepTarget)
    other_name = StatefulAlgorithms.static_findkey(shared_registry, PrepOther)

    sharedcontexts1, sharedvars1 = StatefulAlgorithms._resolve_options(resolved1)
    sharedcontexts2, sharedvars2 = StatefulAlgorithms._resolve_options(resolved2)

    @test haskey(sharedcontexts1, source_name)
    @test StatefulAlgorithms.contextname(only(sharedcontexts1[source_name])) == target_name
    @test haskey(sharedcontexts1, target_name)
    @test StatefulAlgorithms.contextname(only(sharedcontexts1[target_name])) == source_name
    @test haskey(sharedvars1, other_name)
    @test length(sharedvars1[other_name]) == 1
    @test StatefulAlgorithms.get_fromname(only(sharedvars1[other_name])) == source_name
    @test isempty(sharedcontexts2)
    @test isempty(sharedvars2)

    unique_comp = StatefulAlgorithms.resolve(CompositeAlgorithm(Unique(PrepSource()), Unique(PrepSource()), (1, 1)))
    unique_keys = (StatefulAlgorithms.plan_child_namespace(unique_comp, 1), StatefulAlgorithms.plan_child_namespace(unique_comp, 2))
    @test unique_keys[1] != unique_keys[2]
    @test all(child -> child isa PrepSource, StatefulAlgorithms.getalgos(unique_comp))
    @test all(child -> !(child isa StatefulAlgorithms.AbstractIdentifiableAlgo), StatefulAlgorithms.getalgos(unique_comp))
    @test length(StatefulAlgorithms.findall(PrepSource, StatefulAlgorithms.getregistry(unique_comp))) == 2
end
