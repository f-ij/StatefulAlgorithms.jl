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
