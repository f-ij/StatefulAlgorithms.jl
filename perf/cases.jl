# Performance cases: each pairs a package plan with a hand-written loop that
# computes exactly the same thing. `run.jl` checks the results are identical,
# then compares time per step and allocations.

using StatefulAlgorithms
const SA = StatefulAlgorithms

#################
### Algorithms ###
#################

"""`x ← 0.999x + K`: a trivial step, so framework overhead dominates."""
struct Lin{K} <: StepAlgorithm end
SA.init(::Lin, context) = (; x = 0.0)
SA.step!(::Lin{K}, context) where {K} = (; x = context.x * 0.999 + Float64(K))

"""Like `Lin`, but also reads a routed input `u`."""
struct Chain{K} <: StepAlgorithm end
SA.init(::Chain, context) = (; x = 0.0)
SA.step!(::Chain{K}, context) where {K} = (; x = context.x * 0.999 + context.u * 1e-3 + Float64(K))

"""Produces `reading`, which is not declared in `init` (a transient output)."""
struct Sensor <: StepAlgorithm end
SA.init(::Sensor, context) = (; n = 0)
SA.step!(::Sensor, context) = (; n = context.n + 1, reading = Float64(context.n + 1))

"""Consumes the routed transient `reading`."""
struct Controller <: StepAlgorithm end
SA.init(::Controller, context) = (; acc = 0.0)
SA.step!(::Controller, context) = (; acc = context.acc + context.reading)

@inline lin(x, K) = x * 0.999 + Float64(K)

#############
### Cases ###
#############

"""
One benchmark case.

- `plan()` builds the package plan.
- `hand(N)` runs the hand-written equivalent for `N` steps and returns its results.
- `result(context)` extracts the same results from a finished package context.
- `N` is the number of outer steps per timed run and `inner` the number of
  algorithm steps per outer step (used to report ns per algorithm step).
- `target` is the allowed time ratio package / hand-written loop; `max_bytes`
  the allowed allocation per outer step.
"""
Base.@kwdef struct PerfCase
    name::String
    plan::Function
    hand::Function
    result::Function
    N::Int
    inner::Int = 1
    target::Float64 = 1.25
    max_bytes::Float64 = 0.0
    note::String = ""
end

@noinline function hand_flat4(N)
    x1 = x2 = x3 = x4 = 0.0
    for _ in 1:N
        x1 = lin(x1, 1); x2 = lin(x2, 2); x3 = lin(x3, 3); x4 = lin(x4, 4)
    end
    return (x1, x2, x3, x4)
end

@noinline function hand_intervals(N)
    x1 = x2 = 0.0
    for t in 1:N
        x1 = lin(x1, 1)
        t % 3 == 0 && (x2 = lin(x2, 2))
    end
    return (x1, x2)
end

@noinline function hand_route(N)
    x1 = x2 = 0.0
    for t in 1:N
        t % 10 == 0 && (x1 = lin(x1, 1))
        x2 = x2 * 0.999 + x1 * 1e-3 + 2.0
    end
    return (x1, x2)
end

@noinline function hand_nested(N)
    x1 = x2 = x3 = 0.0
    k = 0                              # inner composite's own tick
    for t in 1:N
        if t % 2 == 0
            k += 1
            x1 = lin(x1, 1)
            k % 3 == 0 && (x2 = lin(x2, 2))
        end
        x3 = lin(x3, 3)
    end
    return (x1, x2, x3)
end

@noinline function hand_wide32(N)
    xs = zeros(32)
    for _ in 1:N
        @inbounds for k in 1:32
            xs[k] = lin(xs[k], k)
        end
    end
    return Tuple(xs)
end

@noinline function hand_routine3(N)
    x1 = x2 = x3 = 0.0
    for _ in 1:N
        x1 = lin(x1, 1); x2 = lin(x2, 2); x3 = lin(x3, 3)
    end
    return (x1, x2, x3)
end

@noinline function hand_routine_100_5(N)
    x1 = x2 = 0.0
    for _ in 1:N
        for _ in 1:100; x1 = lin(x1, 1); end
        for _ in 1:5; x2 = lin(x2, 2); end
    end
    return (x1, x2)
end

@noinline function hand_transient(N)
    n = 0; acc = 0.0
    for t in 1:N
        if (t - 1) % 10 == 0
            n += 1
            acc += Float64(n)
        end
    end
    return (n, acc)
end

xs(context, ks...) = map(k -> context[Lin{k}].x, ks)

const CASES = PerfCase[
    PerfCase(name = "flat composite, 4 children", N = 10^7, inner = 4,
        plan = () -> CompositeAlgorithm(Lin{1}, Lin{2}, Lin{3}, Lin{4}, (1, 1, 1, 1)),
        hand = hand_flat4, result = c -> xs(c, 1, 2, 3, 4)),
    PerfCase(name = "intervals (1, 3)", N = 2 * 10^7, inner = 1,
        plan = () -> CompositeAlgorithm(Lin{1}, Lin{2}, (1, 3)),
        hand = hand_intervals, result = c -> xs(c, 1, 2)),
    PerfCase(name = "route from interval-10 producer", N = 10^7,
        plan = () -> CompositeAlgorithm(Lin{1}, Chain{2}, (10, 1), Route(Lin{1} => Chain{2}, :x => :u)),
        hand = hand_route, result = c -> (c[Lin{1}].x, c[Chain{2}].x)),
    PerfCase(name = "nested composite", N = 10^7,
        plan = () -> CompositeAlgorithm(CompositeAlgorithm(Lin{1}, Lin{2}, (1, 3)), Lin{3}, (2, 1)),
        hand = hand_nested, result = c -> xs(c, 1, 2, 3)),
    PerfCase(name = "wide composite, 32 children", N = 10^6, inner = 32,
        plan = () -> CompositeAlgorithm((Lin{k} for k in 1:32)..., ntuple(_ -> 1, 32)),
        hand = hand_wide32, result = c -> xs(c, 1:32...)),
    PerfCase(name = "flat Routine (1, 1, 1)", N = 10^7, inner = 3,
        plan = () -> Routine(Lin{1}, Lin{2}, Lin{3}, (1, 1, 1)),
        hand = hand_routine3, result = c -> xs(c, 1, 2, 3)),
    PerfCase(name = "Routine (100, 5)", N = 10^5, inner = 105,
        plan = () -> Routine(Lin{1}, Lin{2}, (100, 5)),
        hand = hand_routine_100_5, result = c -> xs(c, 1, 2)),
    PerfCase(name = "Routine in Routine", N = 10^6, inner = 3,
        plan = () -> Routine(Routine(Lin{1}, Lin{2}, (1, 1)), Lin{3}, (1, 1)),
        hand = hand_routine3, result = c -> xs(c, 1, 2, 3),
        note = "inner _subroutine_step! becomes a dynamic invoke (recursion limit)"),
    PerfCase(name = "transient route, produced on step 1", N = 10^7,
        plan = () -> CompositeAlgorithm(Sensor, Controller, (Interval(10, :start), Interval(10, :start)), Route(Sensor => Controller, :reading)),
        hand = hand_transient, result = c -> (c[Sensor].n, c[Controller].acc)),
]
