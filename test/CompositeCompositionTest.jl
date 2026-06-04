using Test
using StatefulAlgorithms

struct Fib <: StatefulAlgorithms.ProcessAlgorithm end
struct Luc <: StatefulAlgorithms.ProcessAlgorithm end
struct FinalCounter <: StatefulAlgorithms.ProcessAlgorithm end

function StatefulAlgorithms.init(::FinalCounter, context)
    return (; count = 0, cleaned = false)
end

function StatefulAlgorithms.step!(::FinalCounter, context)
    return (; count = context.count + 1)
end

function StatefulAlgorithms.cleanup(::FinalCounter, context)
    return (; count = context.count + 10, cleaned = true)
end

@testset "Composite composition, flattening, routine" begin
    fdup_inst = StatefulAlgorithms.Unique(Fib())
    fdup_type = StatefulAlgorithms.Unique(Fib)
    ldup = StatefulAlgorithms.Unique(Luc)

    fibluc = CompositeAlgorithm( Fib(), Fib, Luc, (1, 1, 2))
    @test StatefulAlgorithms.intervals(fibluc) == (StatefulAlgorithms.Interval(1), StatefulAlgorithms.Interval(1), StatefulAlgorithms.Interval(2))

    comp_unique = CompositeAlgorithm( Fib(), Fib, fdup_type , (1, 1, 1))
    # reg_unique = StatefulAlgorithms.getregistry(comp_unique)
    # name_fib_inst = StatefulAlgorithms.getkey(reg_unique, Fib())
    # name_fib_type = StatefulAlgorithms.getkey(reg_unique, Fib)
    # name_fdup_type = StatefulAlgorithms.getkey(reg_unique, fdup_type)
    # @test length(unique((name_fib_inst, name_fib_type, name_fdup_type))) == 3

    routine = StatefulAlgorithms.Routine( Fib, Fib(), fibluc , (10, 20, 30))
    @test StatefulAlgorithms.repeats(routine) == (10, 20, 30)
    @test StatefulAlgorithms.lifetime(Process(resolve(routine))) == Repeat(1)

    ffluc = CompositeAlgorithm( fibluc, fdup_inst, Fib, ldup , (10, 5, 2, 1))
    @test StatefulAlgorithms.intervals(ffluc) == (
        StatefulAlgorithms.Interval(10),
        StatefulAlgorithms.Interval(10),
        StatefulAlgorithms.Interval(20),
        StatefulAlgorithms.Interval(5),
        StatefulAlgorithms.Interval(2),
        StatefulAlgorithms.Interval(1),
    )
    @test length(StatefulAlgorithms.getalgos(ffluc)) == 6

    flat_funcs, flat_intervals = StatefulAlgorithms.flatten(ffluc)
    @test length(flat_funcs) == 6
    @test flat_funcs == StatefulAlgorithms.getalgos(ffluc)
    @test flat_intervals == StatefulAlgorithms.intervals(ffluc)

    routed = CompositeAlgorithm(
        Fib,
        Luc,
        (1, 2),
        Route(Fib => Luc, :fiblist => :source_fib),
    )
    routed_flat_funcs, routed_flat_intervals = StatefulAlgorithms.flatten(routed)
    @test routed_flat_funcs == StatefulAlgorithms.getalgos(routed)
    @test routed_flat_intervals == StatefulAlgorithms.intervals(routed)

    resolved_flat_funcs, resolved_flat_intervals = StatefulAlgorithms.flatten(resolve(routed))
    unwrap_identifiable(x) = x isa StatefulAlgorithms.AbstractIdentifiableAlgo ? StatefulAlgorithms.getalgo(x) : x
    unwrapped_resolved = map(unwrap_identifiable, resolved_flat_funcs)
    unwrapped_routed = map(unwrap_identifiable, StatefulAlgorithms.getalgos(routed))
    @test unwrapped_resolved == unwrapped_routed
    @test resolved_flat_intervals == StatefulAlgorithms.intervals(routed)

    inner = @Routine begin
        @alias dynamics = Fib()
        dynamics()
    end
    outer = @CompositeAlgorithm begin
        inner
    end
    loc = StatefulAlgorithms.findkey(outer, :dynamics)

    @test :dynamics in keys(outer)
    @test :dynamics in propertynames(outer)
    @test !isnothing(loc)
    @test !isnothing(StatefulAlgorithms.findkey(typeof(outer), :dynamics))
    @test StatefulAlgorithms.getkey(outer.dynamics) == :dynamics
    @test outer[loc] === outer.dynamics

    # reg_ffluc = StatefulAlgorithms.getregistry(ffluc)
    # name_fib_inst_ff = StatefulAlgorithms.getkey(reg_ffluc, Fib())
    # name_fib_type_ff = StatefulAlgorithms.getkey(reg_ffluc, Fib)
    # name_fdup_inst = StatefulAlgorithms.getkey(reg_ffluc, fdup_inst)
    # @test length(unique((name_fib_inst_ff, name_fib_type_ff, name_fdup_inst))) == 3
end

@testset "Loop algorithm recipes and root final wrapper" begin
    comp_recipe = CompositeAlgorithm(Fib, Luc, (1, 1))
    @test comp_recipe isa CompositeAlgorithmRecipe
    @test !(resolve(comp_recipe) isa CompositeAlgorithmRecipe)

    routine_recipe = Routine(Fib, Luc, (1, 1))
    @test routine_recipe isa RoutineRecipe
    @test !(resolve(routine_recipe) isa RoutineRecipe)

    finalized = finalstep(
        CompositeAlgorithm(FinalCounter, (1,)),
        context -> (; count = context[FinalCounter].count, cleaned = context[FinalCounter].cleaned),
    )
    resolved = resolve(finalized)
    @test resolved isa StatefulAlgorithms.FinalizedAlgorithm
    @test StatefulAlgorithms.isresolved(resolved)
    @test length(resolved) == 1

    p = Process(resolved, repeat = 2)
    run(p)
    result = fetch(p)
    @test result == (; count = 12, cleaned = true)
    @test context(p)[FinalCounter].count == 12
    @test context(p)[FinalCounter].cleaned

    close(p)
    @test fetch(p) == result
    @test context(p)[FinalCounter].count == 12

    inner = finalstep(CompositeAlgorithm(FinalCounter, (1,)), context -> :inner_final)
    nested = @test_logs (:warn, r"root-only") CompositeAlgorithm(inner, Luc, (1, 1))
    @test !(StatefulAlgorithms.getalgo(nested, 1) isa StatefulAlgorithms.FinalizedAlgorithm)
end

@testset "IfWrapped parser options filter constructor inputs" begin
    kept_comp = CompositeAlgorithm(IfWrapped(Fib, true), Luc, (2, 3))
    @test length(StatefulAlgorithms.getalgos(kept_comp)) == 2
    @test StatefulAlgorithms.intervals(kept_comp) == (StatefulAlgorithms.Interval(2), StatefulAlgorithms.Interval(3))

    skipped_comp = CompositeAlgorithm(IfWrapped(Fib, false), Luc, (2, 3))
    @test length(StatefulAlgorithms.getalgos(skipped_comp)) == 1
    @test StatefulAlgorithms.intervals(skipped_comp) == (StatefulAlgorithms.Interval(3),)

    skipped_routine = Routine(IfWrapped(Fib, false), Luc, (2, 3))
    @test length(StatefulAlgorithms.getalgos(skipped_routine)) == 1
    @test StatefulAlgorithms.repeats(skipped_routine) == (3,)

    named_outer = resolve(CompositeAlgorithm(:fib => IfWrapped(Fib, true), Luc, (1, 1)))
    @test StatefulAlgorithms.plan_child_namespace(named_outer, 1) == :fib

    named_inner = resolve(CompositeAlgorithm(IfWrapped(:fib => Fib, true), Luc, (1, 1)))
    @test StatefulAlgorithms.plan_child_namespace(named_inner, 1) == :fib

    @test_throws AssertionError CompositeAlgorithm(IfWrapped(Fib, false), (1,))
end

@testset "Identifiable merge forwarding preserves keyed GeneralState" begin
    left_state = @state begin
        seed = 4
    end
    right_state = @state begin
        scale
    end
    other_state = @state begin
        offset = 2
    end

    left = IdentifiableAlgo(left_state, :_state)
    right = IdentifiableAlgo(right_state, :_state)
    other_key = IdentifiableAlgo(other_state, :other_state)

    @test registry_allowmerge(left)
    @test registry_allowmerge(right)
    @test registry_allowmerge(left, right)
    @test !registry_allowmerge(left, other_key)

    merged = merge(left, right)
    @test getkey(merged) == :_state
    @test StatefulAlgorithms.general_state_fields(getalgo(merged)) == (:seed, :scale)
    @test StatefulAlgorithms.general_state_required_fields(getalgo(merged)) == (:scale,)
    @test StatefulAlgorithms.init(getalgo(merged), (; scale = 3.0)) == (; seed = 4, scale = 3.0)
    @test sprint(show, merged) == "GeneralState(seed = <default>, scale)@_state: GeneralState(seed = <default>, scale)"
end

@testset "separate_nested_namedtuples preserves outer order" begin
    nested = (; a = (; x = 1, y = 2), b = (; z = 3))
    @test StatefulAlgorithms.separate_nested_namedtuples(nested) == (
        (; a = (; x = 1, y = 2)),
        (; b = (; z = 3)),
    )
end
