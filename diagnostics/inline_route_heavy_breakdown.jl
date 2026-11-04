include("inline_route_heavy_benchmark.jl")

using Printf
using Test
using StatefulAlgorithms

const INLINE_ROUTE_BREAKDOWN_STEPS = parse(Int, get(ENV, "INLINE_ROUTE_BREAKDOWN_STEPS", string(INLINE_ROUTE_HEAVY_STEPS)))
const INLINE_ROUTE_BREAKDOWN_RUNS = parse(Int, get(ENV, "INLINE_ROUTE_BREAKDOWN_RUNS", string(INLINE_ROUTE_HEAVY_RUNS)))
const INLINE_ROUTE_BREAKDOWN_SINK = Ref{Any}(nothing)

"""Return the direct loop entrypoint result for an already reset inline process."""
function inline_route_direct_loop(process::IP) where {IP<:StatefulAlgorithms.InlineProcess}
    lifetime = StatefulAlgorithms.lifetime(process)
    session, algo, lc = StatefulAlgorithms.prepare_for_loop(process, StatefulAlgorithms.getcontext(process), (;), lifetime, StatefulAlgorithms.Resuming{false}())
    persistent_context, _ = StatefulAlgorithms.loop(session, algo, lc, lifetime)
    return persistent_context
end

# The generated process-loop entrypoint (`loop(..., Generated())`) is gone: only the `NonGenerated` loop is loaded
# (src/Legacy/GeneratedStep.jl), so its variant was removed.

"""Run the workload through `ProcessContext` directly, bypassing routes and views."""
function inline_route_manual_context_loop(process::IP) where {IP<:StatefulAlgorithms.InlineProcess}
    context = StatefulAlgorithms.getcontext(process)
    steps = StatefulAlgorithms.repeats(StatefulAlgorithms.lifetime(process))

    # This keeps ProcessContext storage and subcontext writeback, but removes
    # SubContextView construction, routed lookup, and stablemerge routing.
    for _ in 1:steps
        sensor = context[:sensor]
        plant = context[:plant]
        controller = context[:controller]
        phase, raw, reference, quality, excitation = inline_route_sensor_kernel(
            sensor.phase,
            sensor.excitation,
            plant.position,
            plant.velocity,
            plant.energy,
            controller.control,
        )
        context = StatefulAlgorithms.merge_into_subcontexts(context, (; sensor = (; phase, raw, reference, quality, excitation)))

        sensor = context[:sensor]
        filter = context[:filter]
        plant = context[:plant]
        estimate, rate, bias, residual, tracking_error = inline_route_filter_kernel(
            filter.estimate,
            filter.rate,
            filter.bias,
            sensor.raw,
            sensor.reference,
            sensor.quality,
            plant.position,
        )
        context = StatefulAlgorithms.merge_into_subcontexts(context, (; filter = (; estimate, rate, bias, residual, tracking_error)))

        sensor = context[:sensor]
        filter = context[:filter]
        controller = context[:controller]
        plant = context[:plant]
        control, integral, command_power, saturation = inline_route_controller_kernel(
            controller.control,
            controller.integral,
            controller.command_power,
            filter.estimate,
            filter.rate,
            filter.bias,
            sensor.reference,
            sensor.quality,
            sensor.excitation,
            plant.load,
        )
        context = StatefulAlgorithms.merge_into_subcontexts(context, (; controller = (; control, integral, command_power, saturation)))

        sensor = context[:sensor]
        filter = context[:filter]
        controller = context[:controller]
        plant = context[:plant]
        position, velocity, energy, load, heat, dt = inline_route_plant_kernel(
            plant.position,
            plant.velocity,
            plant.energy,
            plant.load,
            plant.heat,
            plant.dt,
            controller.control,
            filter.estimate,
            filter.rate,
            sensor.excitation,
            controller.saturation,
        )
        context = StatefulAlgorithms.merge_into_subcontexts(context, (; plant = (; position, velocity, energy, load, heat, dt)))

        sensor = context[:sensor]
        filter = context[:filter]
        controller = context[:controller]
        plant = context[:plant]
        audit = context[:audit]
        checksum, risk, trend, score = inline_route_audit_kernel(
            audit.checksum,
            audit.risk,
            audit.trend,
            audit.score,
            sensor.raw,
            sensor.reference,
            sensor.quality,
            sensor.excitation,
            filter.estimate,
            filter.rate,
            filter.bias,
            filter.residual,
            controller.control,
            controller.command_power,
            controller.saturation,
            plant.position,
            plant.velocity,
            plant.energy,
            plant.load,
            plant.heat,
        )
        context = StatefulAlgorithms.merge_into_subcontexts(context, (; audit = (; checksum, risk, trend, score)))
    end

    return context
end

"""Run from `ProcessContext` values but write back only once after the local loop."""
function inline_route_batched_context_loop(process::IP) where {IP<:StatefulAlgorithms.InlineProcess}
    context = StatefulAlgorithms.getcontext(process)
    steps = StatefulAlgorithms.repeats(StatefulAlgorithms.lifetime(process))

    sensor = context[:sensor]
    filter = context[:filter]
    controller = context[:controller]
    plant = context[:plant]
    audit = context[:audit]

    phase = sensor.phase
    raw = sensor.raw
    reference = sensor.reference
    quality = sensor.quality
    excitation = sensor.excitation

    estimate = filter.estimate
    rate = filter.rate
    bias = filter.bias
    residual = filter.residual
    tracking_error = filter.tracking_error

    control = controller.control
    integral = controller.integral
    command_power = controller.command_power
    saturation = controller.saturation

    position = plant.position
    velocity = plant.velocity
    energy = plant.energy
    load = plant.load
    heat = plant.heat
    dt = plant.dt

    checksum = audit.checksum
    risk = audit.risk
    trend = audit.trend
    score = audit.score

    # This removes per-child context writeback from the hot loop while keeping
    # the same starting and final ProcessContext representation.
    for _ in 1:steps
        phase, raw, reference, quality, excitation = inline_route_sensor_kernel(
            phase,
            excitation,
            position,
            velocity,
            energy,
            control,
        )
        estimate, rate, bias, residual, tracking_error = inline_route_filter_kernel(
            estimate,
            rate,
            bias,
            raw,
            reference,
            quality,
            position,
        )
        control, integral, command_power, saturation = inline_route_controller_kernel(
            control,
            integral,
            command_power,
            estimate,
            rate,
            bias,
            reference,
            quality,
            excitation,
            load,
        )
        position, velocity, energy, load, heat, dt = inline_route_plant_kernel(
            position,
            velocity,
            energy,
            load,
            heat,
            dt,
            control,
            estimate,
            rate,
            excitation,
            saturation,
        )
        checksum, risk, trend, score = inline_route_audit_kernel(
            checksum,
            risk,
            trend,
            score,
            raw,
            reference,
            quality,
            excitation,
            estimate,
            rate,
            bias,
            residual,
            control,
            command_power,
            saturation,
            position,
            velocity,
            energy,
            load,
            heat,
        )
    end

    return StatefulAlgorithms.merge_into_subcontexts(
        context,
        (;
            sensor = (; phase, raw, reference, quality, excitation),
            filter = (; estimate, rate, bias, residual, tracking_error),
            controller = (; control, integral, command_power, saturation),
            plant = (; position, velocity, energy, load, heat, dt),
            audit = (; checksum, risk, trend, score),
        ),
    )
end

"""Run the repeat loop by calling the resolved step plan directly."""
function inline_route_direct_plan_loop(process::IP) where {IP<:StatefulAlgorithms.InlineProcess}
    algo = @inline StatefulAlgorithms.getalgo(process)
    lifetime = @inline StatefulAlgorithms.lifetime(process)
    session = @inline StatefulAlgorithms.getsession(process)
    step_plan = @inline StatefulAlgorithms.getplan(algo)
    step_cursor = @inline StatefulAlgorithms.loop_cursor(step_plan, Val(false))
    step_wiring = @inline StatefulAlgorithms._root_wiring_view(algo, step_plan)
    lc = @inline StatefulAlgorithms.LoopContext(algo, StatefulAlgorithms.getcontext(process))
    persistent_context = @inline StatefulAlgorithms.getpersistent(lc)
    runtime_context = @inline StatefulAlgorithms.getruntime(lc)

    # This mirrors the repeat-lifetime `loop` body and its `_repeat_steps`, minus run entrypoint validation,
    # runtime-input merge (`prepare_for_loop`), timing stamps, cleanup, and context store. Like `loop`, it carries only
    # the fields the steps write (src/Context/Carried/Carry.jl).
    carried = @inline StatefulAlgorithms.create_carried(step_plan, step_cursor, lc, step_wiring, StatefulAlgorithms.Namespace{nothing}(), session, lifetime)
    start_idx = @inline StatefulAlgorithms.loopidx(session)
    end_idx = @inline StatefulAlgorithms.repeats(lifetime)
    for _ in start_idx:end_idx
        if @inline StatefulAlgorithms.lifetime_breakcondition(
            lifetime,
            (@inline StatefulAlgorithms.final_context(StatefulAlgorithms.LoopContext((@inline StatefulAlgorithms.with_carried(persistent_context, carried)), runtime_context))),
            (@inline StatefulAlgorithms.loopint(session)) - 1,
        )
            break
        end
        stepped_lc = @inline StatefulAlgorithms._step!(
            step_plan,
            step_cursor,
            StatefulAlgorithms.LoopContext((@inline StatefulAlgorithms.with_carried(persistent_context, carried)), runtime_context),
            step_wiring,
            StatefulAlgorithms.Namespace{nothing}(),
            session,
            lifetime,
        )
        carried = @inline StatefulAlgorithms.next_carried(carried, (@inline StatefulAlgorithms.getpersistent(stepped_lc)))
        runtime_context = @inline StatefulAlgorithms.getruntime(stepped_lc)
        @inline StatefulAlgorithms.tick!(session)
        @inline StatefulAlgorithms.inc!(session)
        if @inline StatefulAlgorithms.session_breakcondition(session)
            break
        end
    end

    return @inline StatefulAlgorithms.with_carried(persistent_context, carried)
end

"""Measure one benchmark row while excluding setup from the timed expression."""
function inline_route_breakdown_measure(
    setup::S,
    timed::F,
    runs::I,
) where {S<:Function, F<:Function, I<:Integer}
    setup()
    INLINE_ROUTE_BREAKDOWN_SINK[] = timed()

    GC.gc()
    elapsed_ns = 0
    local elapsed_result = nothing
    for _ in 1:runs
        setup()
        start_ns = time_ns()
        elapsed_result = timed()
        elapsed_ns += time_ns() - start_ns
    end
    INLINE_ROUTE_BREAKDOWN_SINK[] = elapsed_result

    GC.gc()
    allocated = 0
    local allocated_result = nothing
    for _ in 1:runs
        setup()
        allocated += @allocated begin
            allocated_result = timed()
        end
    end
    INLINE_ROUTE_BREAKDOWN_SINK[] = allocated_result

    elapsed = elapsed_ns / 1e9
    return (; elapsed, allocated, seconds_per_run = elapsed / runs, bytes_per_run = allocated / runs)
end

"""Assert that each lower-level route entrypoint preserves the benchmark semantics."""
function inline_route_breakdown_check(process::IP, steps::I) where {IP<:StatefulAlgorithms.InlineProcess, I<:Integer}
    plain_summary = inline_route_plain_loop(steps)

    reset!(process)
    run_summary = inline_route_summary(run(process))

    reset!(process)
    loop_summary = inline_route_summary(inline_route_direct_loop(process))

    reset!(process)
    manual_context_summary = inline_route_summary(inline_route_manual_context_loop(process))

    reset!(process)
    batched_context_summary = inline_route_summary(inline_route_batched_context_loop(process))

    reset!(process)
    plan_summary = inline_route_summary(inline_route_direct_plan_loop(process))

    @testset "inline route-heavy breakdown equivalence" begin
        for route_summary in (run_summary, loop_summary, manual_context_summary, batched_context_summary, plan_summary)
            @test keys(route_summary) == keys(plain_summary)
            for key in keys(route_summary)
                @test isapprox(getproperty(route_summary, key), getproperty(plain_summary, key); rtol = 0.0, atol = 1e-12)
            end
        end
    end

    return (; plain_summary, run_summary, loop_summary, manual_context_summary, batched_context_summary, plan_summary)
end

"""Print a compact timing table for the inline route-heavy execution layers."""
function inline_route_print_breakdown_row(name::AbstractString, measure, baseline_seconds::T) where {T<:AbstractFloat}
    @printf(
        "%-24s %12.9f %12.1f %8.3f\n",
        name,
        measure.seconds_per_run,
        measure.bytes_per_run,
        measure.seconds_per_run / baseline_seconds,
    )
    return nothing
end

"""Run entrypoint and route-step breakdown timings for the inline route benchmark."""
function run_inline_route_heavy_breakdown(;
    steps::I = INLINE_ROUTE_BREAKDOWN_STEPS,
    runs::J = INLINE_ROUTE_BREAKDOWN_RUNS,
) where {I<:Integer, J<:Integer}
    process = inline_route_process(steps)
    summaries = inline_route_breakdown_check(process, steps)

    no_setup = () -> nothing
    reset_process = () -> reset!(process)

    plain_measure = inline_route_breakdown_measure(no_setup, () -> inline_route_plain_loop(steps), runs)
    run_measure = inline_route_breakdown_measure(reset_process, () -> run(process), runs)
    loop_measure = inline_route_breakdown_measure(reset_process, () -> inline_route_direct_loop(process), runs)
    manual_context_measure = inline_route_breakdown_measure(reset_process, () -> inline_route_manual_context_loop(process), runs)
    batched_context_measure = inline_route_breakdown_measure(reset_process, () -> inline_route_batched_context_loop(process), runs)
    plan_measure = inline_route_breakdown_measure(reset_process, () -> inline_route_direct_plan_loop(process), runs)

    println("inline_route_breakdown_steps=", steps)
    println("inline_route_breakdown_runs=", runs)
    println("name                      seconds/run    bytes/run    vsplain")
    inline_route_print_breakdown_row("plain_loop", plain_measure, plain_measure.seconds_per_run)
    inline_route_print_breakdown_row("run(process)", run_measure, plain_measure.seconds_per_run)
    inline_route_print_breakdown_row("direct_loop", loop_measure, plain_measure.seconds_per_run)
    inline_route_print_breakdown_row("manual_context_loop", manual_context_measure, plain_measure.seconds_per_run)
    inline_route_print_breakdown_row("batched_context_loop", batched_context_measure, plain_measure.seconds_per_run)
    inline_route_print_breakdown_row("direct_plan_steps", plan_measure, plain_measure.seconds_per_run)
    @printf("run_minus_direct_loop_seconds=%.9f\n", run_measure.seconds_per_run - loop_measure.seconds_per_run)
    @printf("direct_loop_minus_manual_context_seconds=%.9f\n", loop_measure.seconds_per_run - manual_context_measure.seconds_per_run)
    @printf("manual_context_minus_plain_seconds=%.9f\n", manual_context_measure.seconds_per_run - plain_measure.seconds_per_run)
    @printf("batched_context_minus_plain_seconds=%.9f\n", batched_context_measure.seconds_per_run - plain_measure.seconds_per_run)
    @printf("manual_minus_batched_context_seconds=%.9f\n", manual_context_measure.seconds_per_run - batched_context_measure.seconds_per_run)
    @printf("direct_loop_minus_plan_seconds=%.9f\n", loop_measure.seconds_per_run - plan_measure.seconds_per_run)
    @printf("plan_minus_plain_seconds=%.9f\n", plan_measure.seconds_per_run - plain_measure.seconds_per_run)
    @printf("final_checksum=%.12f\n", summaries.run_summary.checksum)

    return (; summaries, plain_measure, run_measure, loop_measure, manual_context_measure, batched_context_measure, plan_measure)
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_inline_route_heavy_breakdown()
end
