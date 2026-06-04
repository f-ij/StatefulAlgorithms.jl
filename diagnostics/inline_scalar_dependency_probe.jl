using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Printf
using Test
using StatefulAlgorithms

const SCALAR_DEPENDENCY_STEPS = parse(Int, get(ENV, "SCALAR_DEPENDENCY_STEPS", "100000"))
const SCALAR_DEPENDENCY_TRIALS = parse(Int, get(ENV, "SCALAR_DEPENDENCY_TRIALS", "100"))
const SCALAR_DEPENDENCY_SINK = Ref{Any}(nothing)

struct DependencySource <: StatefulAlgorithms.ProcessAlgorithm end
struct DependencyMid <: StatefulAlgorithms.ProcessAlgorithm end
struct DependencySink <: StatefulAlgorithms.ProcessAlgorithm end
struct DependencyTopState <: StatefulAlgorithms.ProcessAlgorithm end
struct DependencyFeedback <: StatefulAlgorithms.ProcessAlgorithm end

"""Mutate a tiny preallocated buffer and return a compact checksum contribution."""
function dependency_touch_buffer!(buffer::B, value::T, offset::I) where {T<:AbstractFloat, B<:AbstractVector{T}, I<:Integer}
    index = mod1(offset, length(buffer))
    buffer[index] = muladd(T(0.89), buffer[index], T(0.11) * value)
    return buffer[index]
end

"""Initialize the source state that owns the shared scalar fields."""
function StatefulAlgorithms.init(::A, context::C) where {A<:DependencySource,C<:StatefulAlgorithms.AbstractContext}
    return (;
        x = 0.25,
        feedback = 0.05,
        shared = 0.1,
        checksum = 0.0,
        trace = zeros(Float64, 4),
        scratch = zeros(Float64, 4),
    )
end

"""Initialize the middle stage that consumes source writes in the same iteration."""
function StatefulAlgorithms.init(::A, context::C) where {A<:DependencyMid,C<:StatefulAlgorithms.AbstractContext}
    return (; y = -0.2, mid_accum = 0.0, mid_buffer = zeros(Float64, 3))
end

"""Initialize the sink stage that consumes middle-stage writes in the same iteration."""
function StatefulAlgorithms.init(::A, context::C) where {A<:DependencySink,C<:StatefulAlgorithms.AbstractContext}
    return (; z = 0.3, sink_accum = 0.0, sink_buffer = zeros(Float64, 3))
end

"""Initialize the feedback stage that writes back into the shared source state."""
function StatefulAlgorithms.init(::A, context::C) where {A<:DependencyFeedback,C<:StatefulAlgorithms.AbstractContext}
    return (; local_feedback = 0.0, feedback_accum = 0.0, feedback_buffer = zeros(Float64, 3))
end

"""Advance the source and publish values for later stages in this iteration."""
function StatefulAlgorithms.step!(::A, context::C) where {A<:DependencySource,C<:StatefulAlgorithms.AbstractContext}
    x = muladd(0.91, context.x, 0.07 * context.feedback + 0.02 * context.shared + 0.005 * context.top_signal + 0.001)
    shared = muladd(0.97, context.shared, 0.03 * (x + context.feedback) + 0.0005)
    trace = context.trace
    scratch = context.scratch
    trace_touch = dependency_touch_buffer!(trace, x + shared, 1)
    scratch_touch = dependency_touch_buffer!(scratch, context.feedback - x, 2)
    checksum = muladd(0.999, context.checksum, x + 0.1 * shared + 0.000002 * context.top_metric + 0.01 * (trace_touch + scratch_touch))
    return (; x, shared, checksum, trace, scratch)
end

"""Read source writes, update a middle value, and mutate shared source state."""
function StatefulAlgorithms.step!(::A, context::C) where {A<:DependencyMid,C<:StatefulAlgorithms.AbstractContext}
    trace = context.trace
    scratch = context.scratch
    mid_buffer = context.mid_buffer
    trace_term = dependency_touch_buffer!(trace, context.x + context.shared, 3)
    mid_term = dependency_touch_buffer!(mid_buffer, context.x - context.feedback + trace_term, 1)
    y = muladd(0.83, context.y, 0.12 * context.x - 0.04 * context.feedback + 0.01 * context.shared + 0.005 * mid_term + 0.0003)
    mid_accum = muladd(0.995, context.mid_accum, y + context.x + 0.01 * sum(mid_buffer))
    shared = muladd(0.96, context.shared, 0.04 * (y - context.feedback))
    dependency_touch_buffer!(scratch, y + shared, 4)
    return (; y, mid_accum, shared, trace, scratch, mid_buffer)
end

"""Read middle and source writes, update a sink value, and mutate shared source state again."""
function StatefulAlgorithms.step!(::A, context::C) where {A<:DependencySink,C<:StatefulAlgorithms.AbstractContext}
    trace = context.trace
    scratch = context.scratch
    sink_buffer = context.sink_buffer
    mid_buffer_signal = sum(context.mid_buffer)
    trace_term = dependency_touch_buffer!(trace, context.y + mid_buffer_signal, 5)
    sink_term = dependency_touch_buffer!(sink_buffer, context.y + context.x + trace_term, 1)
    z = muladd(0.79, context.z, 0.16 * context.y + 0.05 * context.x + 0.015 * context.shared + 0.004 * sink_term + 0.0002)
    sink_accum = muladd(0.992, context.sink_accum, z - 0.2 * context.y + 0.01 * sum(sink_buffer))
    shared = muladd(0.955, context.shared, 0.045 * (z + context.y))
    dependency_touch_buffer!(scratch, z - context.y + shared, 6)
    return (; z, sink_accum, shared, trace, scratch, sink_buffer)
end

"""Merge route results into the composite-owned top-level state."""
function StatefulAlgorithms.step!(::A, context::C) where {A<:DependencyTopState,C<:StatefulAlgorithms.AbstractContext}
    top_buffer = context.top_buffer
    top_term = dependency_touch_buffer!(top_buffer, context.z + context.y + context.shared, 1)
    top_signal = muladd(0.81, context.top_signal, 0.11 * context.feedback + 0.06 * context.z + 0.02 * top_term + 0.0001)
    top_metric = muladd(0.94, context.top_metric, 0.04 * top_signal + 0.0001 * context.checksum + 0.0001 * (sum(top_buffer) + sum(context.sink_buffer)))
    return (; top_signal, top_metric, top_buffer)
end

"""Read sink/middle/source writes and write feedback into the shared source state."""
function StatefulAlgorithms.step!(::A, context::C) where {A<:DependencyFeedback,C<:StatefulAlgorithms.AbstractContext}
    trace = context.trace
    scratch = context.scratch
    feedback_buffer = context.feedback_buffer
    route_signal = 0.01 * (sum(context.mid_buffer) + sum(context.sink_buffer)) + 0.002 * sum(context.top_buffer)
    feedback_term = dependency_touch_buffer!(feedback_buffer, context.z - context.y + route_signal, 1)
    dependency_touch_buffer!(trace, feedback_term + context.z, 7)
    dependency_touch_buffer!(scratch, feedback_term - context.y, 8)
    local_feedback = muladd(0.73, context.local_feedback, 0.18 * context.z - 0.06 * context.y + 0.03 * context.shared + 0.015 * context.top_signal + 0.005 * feedback_term + 0.0001)
    feedback_accum = muladd(0.99, context.feedback_accum, local_feedback + context.z + 0.01 * sum(feedback_buffer) + 0.0001 * context.top_metric)
    feedback = muladd(0.88, context.feedback, 0.12 * local_feedback)
    shared = muladd(0.965, context.shared, 0.035 * (feedback + local_feedback))
    checksum = muladd(0.9995, context.checksum, feedback + 0.05 * shared + 0.001 * (sum(trace) + sum(scratch)))
    return (; local_feedback, feedback_accum, feedback, shared, checksum, trace, scratch, feedback_buffer)
end

"""Build the dependency-heavy scalar algorithm with same-iteration reads and shared writes."""
function scalar_dependency_algorithm()
    return @CompositeAlgorithm begin
        @state top_signal = 0.02
        @state top_metric = 0.0
        @state top_buffer = zeros(Float64, 3)

        @alias source = DependencySource()
        @alias mid = DependencyMid()
        @alias sink = DependencySink()
        @alias topstate = DependencyTopState()
        @alias feedbacker = DependencyFeedback()

        source(top_signal = top_signal, top_metric = top_metric)
        mid(@all(source...))
        sink(@all(source...), y = mid.y, mid_buffer = mid.mid_buffer)
        top_signal, top_metric, top_buffer = topstate(
            @all(source...),
            y = mid.y,
            z = sink.z,
            sink_buffer = sink.sink_buffer,
            top_signal = top_signal,
            top_metric = top_metric,
            top_buffer = top_buffer,
        )
        feedbacker(
            @all(source...),
            y = mid.y,
            mid_buffer = mid.mid_buffer,
            z = sink.z,
            sink_buffer = sink.sink_buffer,
            top_signal = top_signal,
            top_metric = top_metric,
            top_buffer = top_buffer,
        )
    end
end

"""Create an inline process for the scalar dependency workload."""
function scalar_dependency_process(steps::I) where {I<:Integer}
    return StatefulAlgorithms.InlineProcess(scalar_dependency_algorithm(); repeats = steps)
end

"""Run the dependency workload as ordinary local variables with the same write order."""
function scalar_dependency_plain(steps::I) where {I<:Integer}
    x = 0.25
    feedback = 0.05
    shared = 0.1
    checksum = 0.0
    trace = zeros(Float64, 4)
    scratch = zeros(Float64, 4)

    y = -0.2
    mid_accum = 0.0
    mid_buffer = zeros(Float64, 3)

    z = 0.3
    sink_accum = 0.0
    sink_buffer = zeros(Float64, 3)

    top_signal = 0.02
    top_metric = 0.0
    top_buffer = zeros(Float64, 3)

    local_feedback = 0.0
    feedback_accum = 0.0
    feedback_buffer = zeros(Float64, 3)

    for _ in 1:steps
        # Source publishes scalar and buffer writes that later stages read in this same iteration.
        x = muladd(0.91, x, 0.07 * feedback + 0.02 * shared + 0.005 * top_signal + 0.001)
        shared = muladd(0.97, shared, 0.03 * (x + feedback) + 0.0005)
        trace_touch = dependency_touch_buffer!(trace, x + shared, 1)
        scratch_touch = dependency_touch_buffer!(scratch, feedback - x, 2)
        checksum = muladd(0.999, checksum, x + 0.1 * shared + 0.000002 * top_metric + 0.01 * (trace_touch + scratch_touch))

        # Middle stage reads source writes and writes back to the shared source state.
        trace_term = dependency_touch_buffer!(trace, x + shared, 3)
        mid_term = dependency_touch_buffer!(mid_buffer, x - feedback + trace_term, 1)
        y = muladd(0.83, y, 0.12 * x - 0.04 * feedback + 0.01 * shared + 0.005 * mid_term + 0.0003)
        mid_accum = muladd(0.995, mid_accum, y + x + 0.01 * sum(mid_buffer))
        shared = muladd(0.96, shared, 0.04 * (y - feedback))
        dependency_touch_buffer!(scratch, y + shared, 4)

        # Sink stage depends on middle-stage writes and continues mutating shared source state.
        mid_buffer_signal = sum(mid_buffer)
        trace_term = dependency_touch_buffer!(trace, y + mid_buffer_signal, 5)
        sink_term = dependency_touch_buffer!(sink_buffer, y + x + trace_term, 1)
        z = muladd(0.79, z, 0.16 * y + 0.05 * x + 0.015 * shared + 0.004 * sink_term + 0.0002)
        sink_accum = muladd(0.992, sink_accum, z - 0.2 * y + 0.01 * sum(sink_buffer))
        shared = muladd(0.955, shared, 0.045 * (z + y))
        dependency_touch_buffer!(scratch, z - y + shared, 6)

        # Top-level state is merged into the composite `_state` and read by the next stage.
        top_term = dependency_touch_buffer!(top_buffer, z + y + shared, 1)
        top_signal = muladd(0.81, top_signal, 0.11 * feedback + 0.06 * z + 0.02 * top_term + 0.0001)
        top_metric = muladd(0.94, top_metric, 0.04 * top_signal + 0.0001 * checksum + 0.0001 * (sum(top_buffer) + sum(sink_buffer)))

        # Feedback stage reads child routes plus the freshly merged top-level state.
        route_signal = 0.01 * (sum(mid_buffer) + sum(sink_buffer)) + 0.002 * sum(top_buffer)
        feedback_term = dependency_touch_buffer!(feedback_buffer, z - y + route_signal, 1)
        dependency_touch_buffer!(trace, feedback_term + z, 7)
        dependency_touch_buffer!(scratch, feedback_term - y, 8)
        local_feedback = muladd(0.73, local_feedback, 0.18 * z - 0.06 * y + 0.03 * shared + 0.015 * top_signal + 0.005 * feedback_term + 0.0001)
        feedback_accum = muladd(0.99, feedback_accum, local_feedback + z + 0.01 * sum(feedback_buffer) + 0.0001 * top_metric)
        feedback = muladd(0.88, feedback, 0.12 * local_feedback)
        shared = muladd(0.965, shared, 0.035 * (feedback + local_feedback))
        checksum = muladd(0.9995, checksum, feedback + 0.05 * shared + 0.001 * (sum(trace) + sum(scratch)))
    end

    return (;
        x,
        feedback,
        shared,
        checksum,
        trace_sum = sum(trace),
        scratch_sum = sum(scratch),
        y,
        mid_accum,
        mid_buffer_sum = sum(mid_buffer),
        z,
        sink_accum,
        sink_buffer_sum = sum(sink_buffer),
        top_signal,
        top_metric,
        top_buffer_sum = sum(top_buffer),
        local_feedback,
        feedback_accum,
        feedback_buffer_sum = sum(feedback_buffer),
    )
end

"""Run the dependency workload through the direct plan entrypoint."""
function scalar_dependency_direct_plan_loop(process::IP) where {IP<:StatefulAlgorithms.InlineProcess}
    algo = @inline StatefulAlgorithms.getalgo(process)
    lifetime = @inline StatefulAlgorithms.lifetime(process)
    plan = @inline StatefulAlgorithms.getplan(algo)
    wiring = @inline StatefulAlgorithms._root_wiring_view(algo, plan)
    context = @inline StatefulAlgorithms.context(process)
    runtimecontext = @inline StatefulAlgorithms._merge_into_globals(StatefulAlgorithms._empty_context(), (; process, lifetime))

    context, runtimecontext = @inline StatefulAlgorithms._step!(
        plan,
        context,
        runtimecontext,
        wiring,
        StatefulAlgorithms.Namespace{nothing}(),
        process,
        lifetime,
    )
    @inline StatefulAlgorithms.inc!(process)

    for _ in (@inline StatefulAlgorithms.loopidx(process)):(@inline StatefulAlgorithms.repeats(lifetime))
        context, runtimecontext = @inline StatefulAlgorithms._step!(
            plan,
            context,
            runtimecontext,
            wiring,
            StatefulAlgorithms.Namespace{nothing}(),
            process,
            lifetime,
        )
        @inline StatefulAlgorithms.inc!(process)
        (@inline StatefulAlgorithms.breakcondition(lifetime, process, context)) && break
    end

    return context
end

"""Run the dependency workload through `StatefulAlgorithms.loop` for an already reset inline process."""
function scalar_dependency_direct_loop(process::IP) where {IP<:StatefulAlgorithms.InlineProcess}
    algo = StatefulAlgorithms.getalgo(process)
    context = StatefulAlgorithms.context(process)
    lifetime = StatefulAlgorithms.lifetime(process)
    runtime_inputs = (;)
    return StatefulAlgorithms.loop(process, algo, context, lifetime, runtime_inputs)
end

"""Run the dependency workload through the generated process-loop entrypoint."""
function scalar_dependency_generated_processloop(process::IP) where {IP<:StatefulAlgorithms.InlineProcess}
    algo = StatefulAlgorithms.getalgo(process)
    context = StatefulAlgorithms.context(process)
    lifetime = StatefulAlgorithms.lifetime(process)
    runtime_inputs = (;)
    return StatefulAlgorithms.loop(
        process,
        algo,
        context,
        lifetime,
        runtime_inputs,
        StatefulAlgorithms.Resuming{false}(),
        StatefulAlgorithms.Generated(),
    )
end

"""Extract comparable scalar values from the process result."""
function scalar_dependency_summary(context::C) where {C<:StatefulAlgorithms.ProcessContext}
    source = context[:source]
    mid = context[:mid]
    sink = context[:sink]
    topstate = context[:_state]
    feedbacker = context[:feedbacker]
    return (;
        x = source.x,
        feedback = source.feedback,
        shared = source.shared,
        checksum = source.checksum,
        trace_sum = sum(source.trace),
        scratch_sum = sum(source.scratch),
        y = mid.y,
        mid_accum = mid.mid_accum,
        mid_buffer_sum = sum(mid.mid_buffer),
        z = sink.z,
        sink_accum = sink.sink_accum,
        sink_buffer_sum = sum(sink.sink_buffer),
        top_signal = topstate.top_signal,
        top_metric = topstate.top_metric,
        top_buffer_sum = sum(topstate.top_buffer),
        local_feedback = feedbacker.local_feedback,
        feedback_accum = feedbacker.feedback_accum,
        feedback_buffer_sum = sum(feedbacker.feedback_buffer),
    )
end

"""Return the minimum elapsed seconds across repeated setup/timed samples."""
function scalar_dependency_best_seconds(setup::S, timed::F, trials::I) where {S<:Function,F<:Function,I<:Integer}
    setup()
    SCALAR_DEPENDENCY_SINK[] = timed()
    GC.gc()

    best_ns = typemax(UInt64)
    for _ in 1:trials
        setup()
        start_ns = time_ns()
        SCALAR_DEPENDENCY_SINK[] = timed()
        best_ns = min(best_ns, time_ns() - start_ns)
    end
    return best_ns / 1e9
end

"""Run the scalar dependency allocation and timing probe."""
function run_scalar_dependency_probe(;
    steps::I = SCALAR_DEPENDENCY_STEPS,
    trials::J = SCALAR_DEPENDENCY_TRIALS,
) where {I<:Integer,J<:Integer}
    process = scalar_dependency_process(steps)
    reset!(process)

    reset!(process)
    run_summary = scalar_dependency_summary(run(process))
    plain_summary = scalar_dependency_plain(steps)
    @test keys(run_summary) == keys(plain_summary)
    for key in keys(run_summary)
        @test isapprox(getproperty(run_summary, key), getproperty(plain_summary, key); rtol = 0.0, atol = 1e-11)
    end
    for entrypoint in (scalar_dependency_direct_loop, scalar_dependency_generated_processloop, scalar_dependency_direct_plan_loop)
        reset!(process)
        entry_summary = scalar_dependency_summary(entrypoint(process))
        @test keys(entry_summary) == keys(plain_summary)
        for key in keys(entry_summary)
            @test isapprox(getproperty(entry_summary, key), getproperty(plain_summary, key); rtol = 0.0, atol = 1e-11)
        end
    end

    reset!(process)
    run(process)
    reset!(process)
    scalar_dependency_direct_loop(process)
    reset!(process)
    scalar_dependency_generated_processloop(process)
    reset!(process)
    scalar_dependency_direct_plan_loop(process)

    reset_alloc = @allocated reset!(process)
    reset!(process)
    run_alloc = @allocated run(process)
    reset!(process)
    direct_loop_alloc = @allocated scalar_dependency_direct_loop(process)
    reset!(process)
    generated_processloop_alloc = @allocated scalar_dependency_generated_processloop(process)
    reset!(process)
    direct_plan_alloc = @allocated scalar_dependency_direct_plan_loop(process)

    run_seconds = scalar_dependency_best_seconds(() -> reset!(process), () -> run(process), trials)
    direct_loop_seconds = scalar_dependency_best_seconds(() -> reset!(process), () -> scalar_dependency_direct_loop(process), trials)
    generated_processloop_seconds = scalar_dependency_best_seconds(() -> reset!(process), () -> scalar_dependency_generated_processloop(process), trials)
    direct_plan_seconds = scalar_dependency_best_seconds(() -> reset!(process), () -> scalar_dependency_direct_plan_loop(process), trials)
    plain_seconds = scalar_dependency_best_seconds(() -> nothing, () -> scalar_dependency_plain(steps), trials)

    println("scalar_dependency_steps=", steps)
    println("scalar_dependency_trials=", trials)
    println("reset_alloc=", reset_alloc)
    println("run_alloc=", run_alloc)
    println("direct_loop_alloc=", direct_loop_alloc)
    println("generated_processloop_alloc=", generated_processloop_alloc)
    println("direct_plan_alloc=", direct_plan_alloc)
    @printf("run_seconds=%.9f\n", run_seconds)
    @printf("direct_loop_seconds=%.9f\n", direct_loop_seconds)
    @printf("generated_processloop_seconds=%.9f\n", generated_processloop_seconds)
    @printf("direct_plan_seconds=%.9f\n", direct_plan_seconds)
    @printf("plain_seconds=%.9f\n", plain_seconds)
    @printf("run_ratio=%.3f\n", run_seconds / plain_seconds)
    @printf("direct_loop_ratio=%.3f\n", direct_loop_seconds / plain_seconds)
    @printf("generated_processloop_ratio=%.3f\n", generated_processloop_seconds / plain_seconds)
    @printf("direct_plan_ratio=%.3f\n", direct_plan_seconds / plain_seconds)
    @printf("final_checksum=%.12f\n", run_summary.checksum)
    @printf("final_shared=%.12f\n", run_summary.shared)
    @printf("final_feedback=%.12f\n", run_summary.feedback)
    @printf("final_top_signal=%.12f\n", run_summary.top_signal)
    @printf("final_top_metric=%.12f\n", run_summary.top_metric)

    return (;
        run_summary,
        plain_summary,
        reset_alloc,
        run_alloc,
        direct_loop_alloc,
        generated_processloop_alloc,
        direct_plan_alloc,
        run_seconds,
        direct_loop_seconds,
        generated_processloop_seconds,
        direct_plan_seconds,
        plain_seconds,
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_scalar_dependency_probe()
end
