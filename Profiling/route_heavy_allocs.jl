# Allocations per call of each piece of one run of the route-heavy algorithm (route_heavy_benchmark.jl), as today's
# `run(plan, context)` (src/LoopAlgorithms/DirectRuns.jl) does them: the run's session and starting `LoopContext`
# (`prepare_for_loop`), steps (`_step!`, the call `loop` makes, src/Loops.jl) and the run's end (`finalizer!`).
#
# Old labels -> new labels (the old API, `LoopRunProcess`, `_merge_into_globals`, `_strip_runtime_inputs` and the
# `Unstable()`/`Stable()` step modes, no longer exists):
#   looprunprocess   -> inline_session    the run's counter object: `InlineSession()` (was `LoopRunProcess(lifetime)`)
#   merge_runtime    -> prepare_for_loop  session + starting `LoopContext` (was the stored context merged with the run's globals)
#   bootstrap_step   -> first_step        `prepare_for_loop` + one `_step!` on the starting `LoopContext`
#   stable_step      -> later_step        one `_step!` on the `LoopContext` after the first step (no step modes any more)
#   stable_100_steps -> later_100_steps   100 such `_step!` calls
#   strip_runtime    -> finalizer         the run's end: cleanup + final result, back to the persistent context (`finalizer!`)
#   with_lifecycle   -> (removed)         the plan holds no context since 2026-11-04, so nothing is rebuilt after a run
#   base_run         -> base_run          unchanged
include(joinpath(@__DIR__, "route_heavy_benchmark.jl"))

const ALLOC_STEPS = parse(Int, get(ENV, "ROUTE_HEAVY_ALLOC_STEPS", "2000"))
const ALLOC_RUNS = parse(Int, get(ENV, "ROUTE_HEAVY_ALLOC_RUNS", "1000"))
const ALLOC_SINK = Ref{Any}(nothing)

"""The starting context and the resolved plan of the route-heavy algorithm (`setup`)."""
route_heavy_prepared() = setup(route_heavy_algorithm())

"""The session, plan and starting `LoopContext` of a direct run of `algo` on `persistent_context`, as `run(algo, context)` gets them."""
function route_heavy_run_start(algo::A, persistent_context::C, lifetime::LT) where {A<:StatefulAlgorithms.AbstractLoopAlgorithm, C<:StatefulAlgorithms.ProcessContext, LT<:StatefulAlgorithms.Lifetime}
    return StatefulAlgorithms.prepare_for_loop(algo, persistent_context, (;), lifetime, StatefulAlgorithms.Resuming{false}())
end

"""Step the plan of `algo` once on `lc` with a fresh cursor, as the loop does, and return the `LoopContext` after the step."""
function route_heavy_step(algo::A, lc::LC, session::S, lifetime::LT) where {A<:StatefulAlgorithms.AbstractLoopAlgorithm, LC<:StatefulAlgorithms.LoopContext, S<:StatefulAlgorithms.ProcessSession, LT<:StatefulAlgorithms.Lifetime}
    plan = StatefulAlgorithms.getplan(algo)
    cursor = StatefulAlgorithms.loop_cursor(plan, Val(false))
    wiring = StatefulAlgorithms.PlanWiringView(StatefulAlgorithms.getwiring(plan))
    return StatefulAlgorithms._step!(plan, cursor, lc, wiring, StatefulAlgorithms.Namespace{nothing}(), session, lifetime)
end

function route_heavy_after_first_step(algo::A, persistent_context::C, lifetime::LT) where {A<:StatefulAlgorithms.AbstractLoopAlgorithm, C<:StatefulAlgorithms.ProcessContext, LT<:StatefulAlgorithms.Lifetime}
    session, plan, lc = route_heavy_run_start(algo, persistent_context, lifetime)
    lc = route_heavy_step(plan, lc, session, lifetime)
    StatefulAlgorithms.tick!(session)
    StatefulAlgorithms.inc!(session)
    return session, plan, lc
end

function route_heavy_later_steps!(algo::A, lc::LC, n::Int) where {A<:StatefulAlgorithms.AbstractLoopAlgorithm, LC<:StatefulAlgorithms.LoopContext}
    lifetime = Repeat(n)
    session = StatefulAlgorithms.InlineSession()
    for _ in 1:n
        lc = route_heavy_step(algo, lc, session, lifetime)
    end
    return lc
end

"""Measure allocations for a repeated benchmark block written with Julia `do` syntax."""
function allocation_per_call(f, label::AbstractString, runs::Int)
    GC.gc()
    bytes = @allocated begin
        local result
        for _ in 1:runs
            result = f()
        end
        ALLOC_SINK[] = result
    end
    println(label, "_bytes_total=", bytes)
    println(label, "_bytes_per_call=", bytes / runs)
end

function main()
    persistent_context, algo = route_heavy_prepared()
    lifetime = Repeat(ALLOC_STEPS)

    # Warm all measured paths before recording allocations.
    warm_result = run(algo, persistent_context; repeats = ALLOC_STEPS)
    session, plan, start_lc = route_heavy_run_start(algo, persistent_context, lifetime)
    step_wiring = StatefulAlgorithms.getwiring(StatefulAlgorithms.getplan(plan))
    session2, plan2, first_lc = route_heavy_after_first_step(algo, persistent_context, lifetime)
    later_lc = route_heavy_later_steps!(plan2, first_lc, 16)
    ALLOC_SINK[] = StatefulAlgorithms.finalizer!(algo, StatefulAlgorithms.getpersistent(later_lc), StatefulAlgorithms.getruntime(later_lc), session2, lifetime)

    println("route_heavy_alloc_steps=", ALLOC_STEPS)
    println("route_heavy_alloc_runs=", ALLOC_RUNS)
    println("step_wiring_type=", typeof(step_wiring))
    println("persistent_context_type=", typeof(persistent_context))
    println("loop_context_type=", typeof(start_lc))

    allocation_per_call("inline_session", ALLOC_RUNS) do
        StatefulAlgorithms.InlineSession()
    end

    allocation_per_call("prepare_for_loop", ALLOC_RUNS) do
        route_heavy_run_start(algo, persistent_context, lifetime)
    end

    allocation_per_call("first_step", ALLOC_RUNS) do
        s, p, lc = route_heavy_run_start(algo, persistent_context, lifetime)
        route_heavy_step(p, lc, s, lifetime)
    end

    allocation_per_call("later_step", ALLOC_RUNS) do
        route_heavy_step(plan2, first_lc, StatefulAlgorithms.InlineSession(), lifetime)
    end

    allocation_per_call("later_100_steps", ALLOC_RUNS) do
        route_heavy_later_steps!(plan2, first_lc, 100)
    end

    allocation_per_call("finalizer", ALLOC_RUNS) do
        StatefulAlgorithms.finalizer!(algo, StatefulAlgorithms.getpersistent(later_lc), StatefulAlgorithms.getruntime(later_lc), session2, lifetime)
    end

    allocation_per_call("base_run", ALLOC_RUNS) do
        run(algo, persistent_context; repeats = ALLOC_STEPS)
    end
end

main()
