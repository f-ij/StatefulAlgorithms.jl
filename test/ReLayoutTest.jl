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

# The types each phase gives for one build: the plan, the resolved plan and the initialized one.
function rl_phase_types(plan)
    resolved = resolve(plan)
    return (; plan = typeof(plan),
              resolved = typeof(resolved),
              initialized = typeof(StatefulAlgorithms.init(resolved)))
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
    end
end

@testset "The untyped and the typed resolve give the same type" begin
    for plan in (rl_values(0), rl_nested(0))
        @test typeof(resolve(plan)) === typeof(StatefulAlgorithms._resolve_plan_typed(plan))
    end
end

@testset "A Unique handle the user holds is a key found from types" begin
    held = Unique(RLCounter())
    p = Process(CompositeAlgorithm(held, Unique(RLCounter()), (1, 1)); repeats = 3)
    run(p); wait(p)
    c = StatefulAlgorithms.context(p)
    read_x(c, h) = c[h].x
    @test (@inferred read_x(c, held)) == 3.0
    T = only(Base.return_types(getindex, (typeof(c), typeof(held))))
    @test isconcretetype(T)
end

@testset "A context with the user's Unique keys can be given back to a Process" begin
    held = Unique(RLCounter())
    plan = CompositeAlgorithm(held, Unique(RLCounter()), (1, 1))
    p = Process(plan; repeats = 2); run(p); wait(p)
    c = StatefulAlgorithms.context(p)
    @test c[held].x == 2.0
    q = Process(plan; context = c, repeats = 3); run(q); wait(q)
    @test StatefulAlgorithms.context(q)[held].x == 5.0
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

@testset "A RunIf on a Unique handle's Var in a nested composite" begin
    b = Unique(RLCounter())
    inner = CompositeAlgorithm(b, RLReader, (1, RunIf(x -> x >= 4.0, Var(b, :x))), Route(b => RLReader, :x))
    ip = InlineProcess(CompositeAlgorithm(inner, (1,)); repeats = 6)
    run(ip)
    c = StatefulAlgorithms.context(ip)
    @test c[b].x == 6.0
    @test c[RLReader].seen == 6.0
    # an edit and a new plan around it start from the schedule with its ids' data
    @test length(StatefulAlgorithms.getalgos(insert(inner, 1, Unique(RLCounter())))) == 3
    changed = setinterval(inner, 2, 5)
    @test CompositeAlgorithm(changed, (1,)) isa Plan
    @test StatefulAlgorithms.getinterval(StatefulAlgorithms.intervals(StatefulAlgorithms.number_unique_ids(changed))[2]) == 5
end

@testset "A schedule changed by a setter stays changed when the plan is numbered again" begin
    ca = setintervals(CompositeAlgorithm(Unique(RLCounter()), RLReader, (1, 2)), (1, 7))
    # A number given to a setter becomes an `Interval`, as in the constructor.
    @test StatefulAlgorithms.intervals(ca) == (Interval(1), Interval(7))
    @test StatefulAlgorithms.intervals(StatefulAlgorithms.number_unique_ids(ca)) == (Interval(1), Interval(7))
    r = setrepeats(StatefulAlgorithms.Routine(RLCounter, RLReader, (2, 3)), (Repeat(4), Repeat(5)))
    @test StatefulAlgorithms.repeats(r) == (4, 5)
end
