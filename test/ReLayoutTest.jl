using Test
using StatefulAlgorithms
using StatefulAlgorithms: Callable

#=
Re-laying out a plan: the same layout built again, with other values or new `Unique` ids. Compiled code is reused when
a phase gives a value of the same type as before, so these tests compare types (no timing).
=#

@StepAlgorithm function RLCounter(@managed(x = 0.0))
    @update x = x + 1.0
    return x
end
@StepAlgorithm function RLReader(x, @managed(seen = 0.0))
    @update seen = x
    return seen
end
struct RLScale
    factor::Float64
end
(s::RLScale)(x) = s.factor * x
rl_bump(n) = n + 1

# The layouts, built from a number `k` that only changes values.
rl_values(k) = CompositeAlgorithm(RLCounter, RLReader, Callable(RLScale(1.0 + k), (:n,), :n), (1, 1, 1),
                                  Route(RLCounter => RLReader, :x), Declaration(n = 1.0 * k))
rl_uniques(k) = (b = Unique(RLCounter()); CompositeAlgorithm(Unique(RLCounter()), b, RLReader, (1, 1, 1), Route(b => RLReader, :x)))
rl_nested(k) = CompositeAlgorithm(CompositeAlgorithm(Unique(RLCounter()), Callable(RLScale(1.0 + k), (:n,), :m), (1, 1), Declaration(m = 0.0)),
                                  StatefulAlgorithms.Routine(Unique(RLCounter()), Callable(rl_bump, (:n,), :n), (3, 2)), (1, 1), Declaration(n = 1.0 * k))

# The types each phase compiles for, for one build: the plan, the resolved plan and the initialized context, without the
# registry's `UniqueKeyMap` (`strip_keymap`), as `init` and the loop get them; `keymap` the map `resolve` put in.
function rl_phase_types(plan)
    resolved = resolve(plan)
    return (; plan = typeof(plan),
              resolved = typeof(StatefulAlgorithms.strip_keymap(resolved)),
              initialized = typeof(StatefulAlgorithms.strip_keymap(Base.first(setup(resolved)))),
              keymap = StatefulAlgorithms.getkeymap(resolved))
end

@testset "Re-layout with other values reuses every phase" begin
    first, again = rl_phase_types(rl_values(0)), rl_phase_types(rl_values(1))
    @test first.plan === again.plan
    @test first.resolved === again.resolved
    @test first.initialized === again.initialized
end

@testset "Re-layout with new Unique ids reuses every phase" begin
    for layout in (rl_uniques, rl_nested)
        first, again = rl_phase_types(layout(0)), rl_phase_types(layout(1))
        # The plan, its registry and its context hold numbered ids, no uuids: nothing compiles again for new handles.
        @test first.plan === again.plan
        @test first.resolved === again.resolved
        @test first.initialized === again.initialized
        # Until it is run, the resolved plan's registry carries the uuids, as its `UniqueKeyMap`.
        @test first.keymap isa StatefulAlgorithms.UniqueKeyMap
        @test first.keymap !== again.keymap
    end
end

@testset "The untyped and the typed resolve give the same type" begin
    for plan in (rl_values(0), rl_nested(0))
        # The typed resolve takes the plan numbered, as `resolve` gives it to its steps.
        @test typeof(StatefulAlgorithms.strip_keymap(resolve(plan))) === typeof(StatefulAlgorithms._resolve_plan_typed(StatefulAlgorithms.number_unique_ids(plan)))
    end
end

@testset "A Unique handle the user holds is a key found from types" begin
    held = Unique(RLCounter())
    p = Process(CompositeAlgorithm(held, Unique(RLCounter()), (1, 1)); repeats = 3)
    run(p); wait(p)
    c = getcontext(p)
    read_x(c, h) = c[h].x
    @test (@inferred read_x(c, held)) == 3.0
    T = only(Base.return_types(getindex, (typeof(c), typeof(held))))
    @test isconcretetype(T)
end

@testset "A context with the user's Unique keys can be given back to a Process" begin
    held = Unique(RLCounter())
    plan = CompositeAlgorithm(held, Unique(RLCounter()), (1, 1))
    p = Process(plan; repeats = 2); run(p); wait(p)
    c = getcontext(p)
    @test c[held].x == 2.0
    q = Process(plan; context = c, repeats = 3); run(q); wait(q)
    @test getcontext(q)[held].x == 5.0
    # The process works with the context without the key map: same type as a fresh process's
    @test typeof(StatefulAlgorithms.getalgo(q)) === typeof(StatefulAlgorithms.getalgo(p))
end

# A `Var` of a `Unique` handle in a schedule: a `Routine`'s lifetime or a composite's `RunIf`.
rl_var_lifetime(k) = (a = Unique(RLCounter()); StatefulAlgorithms.Routine(a, RLReader, (RepeatOrUntil(x -> x >= 3.0, 100, Var(a, :x)), 1), Route(a => RLReader, :x)))
rl_var_runif(k) = (b = Unique(RLCounter()); CompositeAlgorithm(b, RLReader, (1, RunIf(x -> x >= 4.0, Var(b, :x))), Route(b => RLReader, :x)))

@testset "Re-layout with a Unique handle's Var in the schedule reuses every phase" begin
    for layout in (rl_var_lifetime, rl_var_runif)
        first, again = rl_phase_types(layout(0)), rl_phase_types(layout(1))
        @test first.plan === again.plan
        @test first.resolved === again.resolved
        @test first.initialized === again.initialized
    end
end

@testset "The untyped and the typed resolve give the same type with a Var in the schedule" begin
    # Step 5 (each schedule `Var` gets its context key) is in both resolves; the key is in the `Var`'s type.
    rl_var_nested(k) = CompositeAlgorithm(rl_var_runif(k), (1,))
    for plan in (rl_var_lifetime(0), rl_var_runif(0), rl_var_nested(0))
        @test typeof(StatefulAlgorithms.strip_keymap(resolve(plan))) === typeof(@inferred StatefulAlgorithms._resolve_plan_typed(StatefulAlgorithms.number_unique_ids(plan)))
    end
end

@testset "A RunIf on a Unique handle's Var in a nested composite" begin
    b = Unique(RLCounter())
    inner = CompositeAlgorithm(b, RLReader, (1, RunIf(x -> x >= 4.0, Var(b, :x))), Route(b => RLReader, :x))
    ip = InlineProcess(CompositeAlgorithm(inner, (1,)); repeats = 6)
    run(ip)
    c = getcontext(ip)
    @test c[b].x == 6.0
    @test c[RLReader].seen == 6.0
    # an edit and a new plan around it start from the schedule with its ids' data
    @test length(StatefulAlgorithms.getalgos(insert(inner, 1, Unique(RLCounter())))) == 3
    changed = setinterval(inner, 2, 5)
    @test CompositeAlgorithm(changed, (1,)) isa CompositeAlgorithm
    @test StatefulAlgorithms.getinterval(StatefulAlgorithms.intervals(StatefulAlgorithms.number_unique_ids(changed))[2]) == 5
end

@testset "A schedule changed by a setter stays changed when the plan is numbered again" begin
    ca = setintervals(CompositeAlgorithm(Unique(RLCounter()), RLReader, (1, 2)), (1, 7))
    @test StatefulAlgorithms.intervals(ca) == (1, 7)
    @test StatefulAlgorithms.intervals(StatefulAlgorithms.number_unique_ids(ca)) == (1, 7)
    r = setrepeats(StatefulAlgorithms.Routine(RLCounter, RLReader, (2, 3)), (Repeat(4), Repeat(5)))
    @test StatefulAlgorithms.repeats(r) == (4, 5)
end

@testset "UniquePlanId: numbered ids match by number, a dynamic one by uuid" begin
    SA = StatefulAlgorithms
    eq = SA.matcher_equals
    u1, u2 = SA.uuid4(), SA.uuid4()
    held = SA.UniquePlanId(u1)
    dyn = SA.make_dynamic(held)
    one, other_one, two = SA.make_numbered(held, 1), SA.make_numbered(SA.UniquePlanId(u2), 1), SA.make_numbered(held, 2)
    @test dyn isa SA.DynamicPlanId && SA.is_dynamic_unique_id(dyn) && SA.origin(dyn) == u1
    @test SA.is_numbered_unique_id(one) && SA.is_held_unique_id(SA.make_held(one)) && SA.make_held(one) === held
    # Two numbered ids: by number only, decided while compiling.
    @test eq(one, other_one) && !eq(one, two)
    @test Base.return_types(eq, (typeof(one), typeof(two))) == [Bool]
    @test only(Base.code_typed(eq, (typeof(one), typeof(two)))).first.code[end].val === false
    # A dynamic id against any form, or a held against a numbered one: by uuid.
    @test eq(dyn, one) && eq(one, dyn) && eq(dyn, held) && eq(held, one) && eq(one, held)
    @test !eq(dyn, SA.DynamicPlanId(u2)) && !eq(SA.DynamicPlanId(u2), one)
    # `match` and the untyped `dynamic_equals` give the same answer both ways round.
    @test SA.match(one, dyn) && SA.match(dyn, one) && !SA.match(two, SA.DynamicPlanId(u2))
    @test SA.dynamic_equals(dyn, one) && !SA.dynamic_equals(two, SA.DynamicPlanId(u2))
    # `==` is Base's own: two ids are `==` only when identical.
    @test one != other_one && dyn != one
    # A held id is made again from its type; a dynamic one is not (its uuid is only in the value).
    @test SA.reconstruct_matcher(typeof(held)) === held
    @test_throws ErrorException SA.reconstruct_matcher(SA.DynamicPlanId)
end
