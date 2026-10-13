# Performance cases: each pairs a package plan with a hand-written loop that
# computes exactly the same thing. `run.jl` checks the results are identical,
# then compares time per step and allocations.

using StatefulAlgorithms
const SA = StatefulAlgorithms

"""
`NoStopRepeat(n)`: `n` repeats like `Repeat(n)`, but its stop check is always `false`, so a `Process` running it never
reads `shouldrun` (not before routine repeats, not after steps) and cannot be paused or closed early. Perf only: the
`process, no stop checks` runner uses it to measure what the stop checks cost, which a hand-written loop does not pay.
"""
struct NoStopRepeat <: SA.RepeatLifetime
    repeats::Int
end
SA.breakcondition(::NoStopRepeat, process, context) = false

#################
### Algorithms ###
#################

# `Lin1` … `Lin32`: `x ← 0.999x + K` for `K` = 1 … 32, a trivial step, so framework overhead dominates. `LIN[K]`
# is the one for `K`; each is its own type, as the plans need.
for K in 1:32
    @eval @StepAlgorithm function $(Symbol(:Lin, K))(@managed(x = 0.0))
        @update x = x * 0.999 + $(Float64(K))
    end
end
const LIN = ntuple(K -> getfield(@__MODULE__, Symbol(:Lin, K)), 32)

"""Like `Lin2`, but also reads a routed input `u`."""
@StepAlgorithm function Chain2(u, @managed(x = 0.0))
    @update x = x * 0.999 + u * 1e-3 + 2.0
end

"""Writes `reading`, a name that is not its state (a transient output, routed to `Controller`)."""
@StepAlgorithm function Sensor(@managed(n = 0); reading = nothing)
    @update n += 1
    @update reading = Float64(n)
end

"""Consumes the routed transient `reading`."""
@StepAlgorithm function Controller(reading, @managed(acc = 0.0))
    @update acc += reading
end

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

"""Routine(Routine(Lin1, Lin2, (10, 5)), Lin3, (3, 2)): 47 algorithm steps per outer step."""
@noinline function hand_routine_nested_repeats(N)
    x1 = x2 = x3 = 0.0
    for _ in 1:N
        for _ in 1:3
            for _ in 1:10; x1 = lin(x1, 1); end
            for _ in 1:5; x2 = lin(x2, 2); end
        end
        for _ in 1:2; x3 = lin(x3, 3); end
    end
    return (x1, x2, x3)
end

"""Routine(Routine(Routine(Lin1, Lin2, (1, 2)), Lin3, (2, 1)), Lin4, (1, 3)): 10 algorithm steps per outer step."""
@noinline function hand_routine_3level(N)
    x1 = x2 = x3 = x4 = 0.0
    for _ in 1:N
        for _ in 1:2
            x1 = lin(x1, 1)
            for _ in 1:2; x2 = lin(x2, 2); end
        end
        x3 = lin(x3, 3)
        for _ in 1:3; x4 = lin(x4, 4); end
    end
    return (x1, x2, x3, x4)
end

"""CompositeAlgorithm(Routine(Lin1, Lin2, (2, 3)), Lin3, (2, 1)): the routine runs every 2nd tick."""
@noinline function hand_routine_in_composite(N)
    x1 = x2 = x3 = 0.0
    for t in 1:N
        if t % 2 == 0
            for _ in 1:2; x1 = lin(x1, 1); end
            for _ in 1:3; x2 = lin(x2, 2); end
        end
        x3 = lin(x3, 3)
    end
    return (x1, x2, x3)
end

"""Routine(CompositeAlgorithm(Lin1, Lin2, (1, 2)), Lin3, (4, 1)): the composite keeps its own tick."""
@noinline function hand_composite_in_routine(N)
    x1 = x2 = x3 = 0.0
    k = 0
    for _ in 1:N
        for _ in 1:4
            k += 1
            x1 = lin(x1, 1)
            k % 2 == 0 && (x2 = lin(x2, 2))
        end
        x3 = lin(x3, 3)
    end
    return (x1, x2, x3)
end

xs(context, ks...) = map(k -> context[LIN[k]].x, ks)

const CASES = PerfCase[
    PerfCase(name = "flat composite, 4 children", N = 10^7, inner = 4,
        plan = () -> CompositeAlgorithm(LIN[1], LIN[2], LIN[3], LIN[4], (1, 1, 1, 1)),
        hand = hand_flat4, result = c -> xs(c, 1, 2, 3, 4)),
    PerfCase(name = "intervals (1, 3)", N = 2 * 10^7, inner = 1,
        plan = () -> CompositeAlgorithm(LIN[1], LIN[2], (1, 3)),
        hand = hand_intervals, result = c -> xs(c, 1, 2)),
    PerfCase(name = "route from interval-10 producer", N = 10^7,
        plan = () -> CompositeAlgorithm(LIN[1], Chain2, (10, 1), Route(LIN[1] => Chain2, :x => :u)),
        hand = hand_route, result = c -> (c[LIN[1]].x, c[Chain2].x)),
    PerfCase(name = "nested composite", N = 10^7,
        plan = () -> CompositeAlgorithm(CompositeAlgorithm(LIN[1], LIN[2], (1, 3)), LIN[3], (2, 1)),
        hand = hand_nested, result = c -> xs(c, 1, 2, 3)),
    PerfCase(name = "wide composite, 32 children", N = 10^6, inner = 32,
        plan = () -> CompositeAlgorithm((LIN[k] for k in 1:32)..., ntuple(_ -> 1, 32)),
        hand = hand_wide32, result = c -> xs(c, 1:32...)),
    PerfCase(name = "flat Routine (1, 1, 1)", N = 10^7, inner = 3,
        plan = () -> Routine(LIN[1], LIN[2], LIN[3], (1, 1, 1)),
        hand = hand_routine3, result = c -> xs(c, 1, 2, 3)),
    PerfCase(name = "Routine (100, 5)", N = 10^5, inner = 105,
        plan = () -> Routine(LIN[1], LIN[2], (100, 5)),
        hand = hand_routine_100_5, result = c -> xs(c, 1, 2)),
    PerfCase(name = "Routine in Routine", N = 10^6, inner = 3,
        plan = () -> Routine(Routine(LIN[1], LIN[2], (1, 1)), LIN[3], (1, 1)),
        hand = hand_routine3, result = c -> xs(c, 1, 2, 3),
        note = "inner _subroutine_step! becomes a dynamic invoke (recursion limit)"),
    PerfCase(name = "Routine in Routine, repeats", N = 2 * 10^5, inner = 47,
        plan = () -> Routine(Routine(LIN[1], LIN[2], (10, 5)), LIN[3], (3, 2)),
        hand = hand_routine_nested_repeats, result = c -> xs(c, 1, 2, 3)),
    PerfCase(name = "3-level Routine", N = 10^6, inner = 10,
        plan = () -> Routine(Routine(Routine(LIN[1], LIN[2], (1, 2)), LIN[3], (2, 1)), LIN[4], (1, 3)),
        hand = hand_routine_3level, result = c -> xs(c, 1, 2, 3, 4)),
    PerfCase(name = "Routine in composite", N = 4 * 10^6,
        plan = () -> CompositeAlgorithm(Routine(LIN[1], LIN[2], (2, 3)), LIN[3], (2, 1)),
        hand = hand_routine_in_composite, result = c -> xs(c, 1, 2, 3)),
    PerfCase(name = "composite in Routine", N = 2 * 10^6,
        plan = () -> Routine(CompositeAlgorithm(LIN[1], LIN[2], (1, 2)), LIN[3], (4, 1)),
        hand = hand_composite_in_routine, result = c -> xs(c, 1, 2, 3)),
    PerfCase(name = "transient route, produced on step 1", N = 10^7,
        plan = () -> CompositeAlgorithm(Sensor, Controller, (Interval(10, :start), Interval(10, :start)), Route(Sensor => Controller, :reading)),
        hand = hand_transient, result = c -> (c[Sensor].n, c[Controller].acc)),
]
