using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Printf
using Test
using StatefulAlgorithms

const INLINE_ROUTE_HEAVY_STEPS = parse(Int, get(ENV, "INLINE_ROUTE_HEAVY_STEPS", "20000"))
const INLINE_ROUTE_HEAVY_RUNS = parse(Int, get(ENV, "INLINE_ROUTE_HEAVY_RUNS", "40"))
const INLINE_ROUTE_HEAVY_SINK = Ref{Any}(nothing)

struct InlineRouteSensor <: StatefulAlgorithms.ProcessAlgorithm end
struct InlineRouteFilter <: StatefulAlgorithms.ProcessAlgorithm end
struct InlineRouteController <: StatefulAlgorithms.ProcessAlgorithm end
struct InlineRoutePlant <: StatefulAlgorithms.ProcessAlgorithm end
struct InlineRouteAudit <: StatefulAlgorithms.ProcessAlgorithm end

"""Update the synthetic sensor state from the previous plant and controller state."""
function inline_route_sensor_kernel(
    phase::T,
    excitation::T,
    position::T,
    velocity::T,
    energy::T,
    control::T,
) where {T<:AbstractFloat}
    # The signal deliberately mixes several routed values so each downstream
    # algorithm depends on more than one producer.
    new_phase = phase + T(0.017) + T(0.001) * control
    reference = T(0.65) * sin(new_phase) + T(0.15) * cos(T(0.37) * new_phase)
    disturbance = T(0.04) * sin(T(1.7) * new_phase + energy)
    raw = position + T(0.12) * velocity + disturbance + T(0.015) * control
    quality = max(T(0.05), min(T(1.0), T(0.96) - T(0.015) * abs(energy) + T(0.02) * cos(new_phase)))
    new_excitation = muladd(T(0.93), excitation, T(0.07) * abs(reference - raw) + T(0.01) * abs(velocity))
    return new_phase, raw, reference, quality, new_excitation
end

"""Estimate position and drift from routed sensor and plant information."""
function inline_route_filter_kernel(
    estimate::T,
    rate::T,
    bias::T,
    raw::T,
    reference::T,
    quality::T,
    position::T,
) where {T<:AbstractFloat}
    residual = raw - estimate
    gain = T(0.18) + T(0.27) * quality

    # Keep the estimator lightweight but stateful enough to behave like real work.
    new_estimate = estimate + gain * residual + T(0.03) * rate
    new_rate = muladd(T(0.82), rate, T(0.18) * (new_estimate - estimate) + T(0.015) * (position - new_estimate))
    new_bias = muladd(T(0.995), bias, T(0.005) * (raw - reference))
    tracking_error = reference - new_estimate
    return new_estimate, new_rate, new_bias, residual, tracking_error
end

"""Compute a bounded controller command from the filtered routed state."""
function inline_route_controller_kernel(
    control::T,
    integral::T,
    command_power::T,
    estimate::T,
    rate::T,
    bias::T,
    reference::T,
    quality::T,
    excitation::T,
    load::T,
) where {T<:AbstractFloat}
    error = reference - estimate - bias
    new_integral = max(T(-2.5), min(T(2.5), muladd(T(0.98), integral, error * quality)))
    feedforward = T(0.12) * excitation - T(0.05) * load
    raw_control = T(1.25) * error - T(0.34) * rate + T(0.08) * new_integral + feedforward
    limit = T(1.15) + T(0.05) * quality
    new_control = max(-limit, min(limit, raw_control))
    new_command_power = muladd(T(0.92), command_power, T(0.08) * abs(new_control * raw_control))
    saturation = abs(raw_control - new_control)
    return new_control, new_integral, new_command_power, saturation
end

"""Advance the plant dynamics from routed controller and estimator outputs."""
function inline_route_plant_kernel(
    position::T,
    velocity::T,
    energy::T,
    load::T,
    heat::T,
    dt::T,
    control::T,
    estimate::T,
    rate::T,
    excitation::T,
    saturation::T,
) where {T<:AbstractFloat}
    new_load = muladd(T(0.88), load, T(0.12) * (T(0.4) + T(0.2) * sin(position) + T(0.1) * abs(rate)))
    acceleration = control - T(0.21) * velocity - T(0.33) * position - T(0.08) * new_load + T(0.025) * estimate

    # The plant uses a small integrator and derived energy/heat bookkeeping.
    new_velocity = velocity + dt * acceleration
    new_position = position + dt * new_velocity + T(0.0005) * excitation
    new_heat = muladd(T(0.97), heat, T(0.03) * (abs(control) * abs(new_velocity) + saturation))
    new_energy = muladd(T(0.992), energy, T(0.5) * (new_position^2 + new_velocity^2) + T(0.02) * new_heat)
    return new_position, new_velocity, new_energy, new_load, new_heat, dt
end

"""Fold all routed subsystem outputs into audit metrics and a checksum."""
function inline_route_audit_kernel(
    checksum::T,
    risk::T,
    trend::T,
    score::T,
    raw::T,
    reference::T,
    quality::T,
    excitation::T,
    estimate::T,
    rate::T,
    bias::T,
    residual::T,
    control::T,
    command_power::T,
    saturation::T,
    position::T,
    velocity::T,
    energy::T,
    load::T,
    heat::T,
) where {T<:AbstractFloat}
    tracking = abs(reference - estimate) + abs(raw - position) + T(0.1) * abs(residual + bias)
    new_risk = muladd(T(0.94), risk, T(0.06) * (tracking + saturation + T(0.01) * energy + (one(T) - quality)))
    new_trend = muladd(T(0.97), trend, T(0.03) * (control + velocity - load + T(0.05) * excitation))
    new_score = muladd(T(0.985), score, quality - new_risk + T(0.02) * command_power - T(0.01) * heat + T(0.001) * rate)
    new_checksum = muladd(T(0.9991), checksum, new_score + T(0.1) * new_risk + T(0.01) * position)
    return new_checksum, new_risk, new_trend, new_score
end

"""Initialize the sensor's local scalar state."""
function StatefulAlgorithms.init(::InlineRouteSensor, context::C) where {C}
    return (; phase = 0.2, raw = 0.25, reference = 0.0, quality = 0.9, excitation = 0.1)
end

"""Step the sensor and expose the routed signal fields."""
function StatefulAlgorithms.step!(::InlineRouteSensor, context::C) where {C}
    phase, raw, reference, quality, excitation = inline_route_sensor_kernel(
        context.phase,
        context.excitation,
        context.position,
        context.velocity,
        context.energy,
        context.control,
    )
    return (; phase, raw, reference, quality, excitation)
end

"""Initialize the estimator's local scalar state."""
function StatefulAlgorithms.init(::InlineRouteFilter, context::C) where {C}
    return (; estimate = 0.2, rate = 0.0, bias = 0.0, residual = 0.0, tracking_error = 0.0)
end

"""Step the estimator from routed sensor and plant values."""
function StatefulAlgorithms.step!(::InlineRouteFilter, context::C) where {C}
    estimate, rate, bias, residual, tracking_error = inline_route_filter_kernel(
        context.estimate,
        context.rate,
        context.bias,
        context.raw,
        context.reference,
        context.quality,
        context.position,
    )
    return (; estimate, rate, bias, residual, tracking_error)
end

"""Initialize the controller's local scalar state."""
function StatefulAlgorithms.init(::InlineRouteController, context::C) where {C}
    return (; control = 0.0, integral = 0.0, command_power = 0.0, saturation = 0.0)
end

"""Step the controller from routed estimator, sensor, and plant values."""
function StatefulAlgorithms.step!(::InlineRouteController, context::C) where {C}
    control, integral, command_power, saturation = inline_route_controller_kernel(
        context.control,
        context.integral,
        context.command_power,
        context.estimate,
        context.rate,
        context.bias,
        context.reference,
        context.quality,
        context.excitation,
        context.load,
    )
    return (; control, integral, command_power, saturation)
end

"""Initialize the plant's local scalar state."""
function StatefulAlgorithms.init(::InlineRoutePlant, context::C) where {C}
    return (; position = 0.25, velocity = -0.08, energy = 0.2, load = 0.15, heat = 0.02, dt = 0.015)
end

"""Step the plant from routed controller and estimator values."""
function StatefulAlgorithms.step!(::InlineRoutePlant, context::C) where {C}
    position, velocity, energy, load, heat, dt = inline_route_plant_kernel(
        context.position,
        context.velocity,
        context.energy,
        context.load,
        context.heat,
        context.dt,
        context.control,
        context.estimate,
        context.rate,
        context.excitation,
        context.saturation,
    )
    return (; position, velocity, energy, load, heat, dt)
end

"""Initialize the audit metrics."""
function StatefulAlgorithms.init(::InlineRouteAudit, context::C) where {C}
    return (; checksum = 0.0, risk = 0.0, trend = 0.0, score = 0.0)
end

"""Step the audit metrics from every routed subsystem output."""
function StatefulAlgorithms.step!(::InlineRouteAudit, context::C) where {C}
    checksum, risk, trend, score = inline_route_audit_kernel(
        context.checksum,
        context.risk,
        context.trend,
        context.score,
        context.raw,
        context.reference,
        context.quality,
        context.excitation,
        context.estimate,
        context.rate,
        context.bias,
        context.residual,
        context.control,
        context.command_power,
        context.saturation,
        context.position,
        context.velocity,
        context.energy,
        context.load,
        context.heat,
    )
    return (; checksum, risk, trend, score)
end

"""Build the five-stage routed algorithm used by the inline benchmark."""
function inline_route_heavy_algorithm()
    return @CompositeAlgorithm begin
        @alias sensor = InlineRouteSensor()
        @alias filter = InlineRouteFilter()
        @alias controller = InlineRouteController()
        @alias plant = InlineRoutePlant()
        @alias audit = InlineRouteAudit()

        sensor(
            position = plant.position,
            velocity = plant.velocity,
            energy = plant.energy,
            control = controller.control,
        )
        filter(
            raw = sensor.raw,
            reference = sensor.reference,
            quality = sensor.quality,
            position = plant.position,
        )
        controller(
            estimate = filter.estimate,
            rate = filter.rate,
            bias = filter.bias,
            reference = sensor.reference,
            quality = sensor.quality,
            excitation = sensor.excitation,
            load = plant.load,
        )
        plant(
            control = controller.control,
            estimate = filter.estimate,
            rate = filter.rate,
            excitation = sensor.excitation,
            saturation = controller.saturation,
        )
        audit(
            raw = sensor.raw,
            reference = sensor.reference,
            quality = sensor.quality,
            excitation = sensor.excitation,
            estimate = filter.estimate,
            rate = filter.rate,
            bias = filter.bias,
            residual = filter.residual,
            control = controller.control,
            command_power = controller.command_power,
            saturation = controller.saturation,
            position = plant.position,
            velocity = plant.velocity,
            energy = plant.energy,
            load = plant.load,
            heat = plant.heat,
        )
    end
end

"""Run the same route-heavy semantics as ordinary scalar variables in one loop."""
function inline_route_plain_loop(steps::I) where {I<:Integer}
    phase = 0.2
    raw = 0.25
    reference = 0.0
    quality = 0.9
    excitation = 0.1

    estimate = 0.2
    rate = 0.0
    bias = 0.0
    residual = 0.0
    tracking_error = 0.0

    control = 0.0
    integral = 0.0
    command_power = 0.0
    saturation = 0.0

    position = 0.25
    velocity = -0.08
    energy = 0.2
    load = 0.15
    heat = 0.02
    dt = 0.015

    checksum = 0.0
    risk = 0.0
    trend = 0.0
    score = 0.0

    # This mirrors the routed CompositeAlgorithm order exactly.
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

    return (;
        phase,
        raw,
        reference,
        quality,
        excitation,
        estimate,
        rate,
        bias,
        residual,
        tracking_error,
        control,
        integral,
        command_power,
        saturation,
        position,
        velocity,
        energy,
        load,
        heat,
        dt,
        checksum,
        risk,
        trend,
        score,
    )
end

"""Extract comparable scalar outputs from a routed inline process result."""
function inline_route_summary(result::R) where {R<:Union{StatefulAlgorithms.AbstractLoopAlgorithm, StatefulAlgorithms.ProcessContext}}
    ctx = result isa StatefulAlgorithms.AbstractLoopAlgorithm ? StatefulAlgorithms.context(result) : result
    sensor = ctx[:sensor]
    filter = ctx[:filter]
    controller = ctx[:controller]
    plant = ctx[:plant]
    audit = ctx[:audit]

    return (;
        phase = sensor.phase,
        raw = sensor.raw,
        reference = sensor.reference,
        quality = sensor.quality,
        excitation = sensor.excitation,
        estimate = filter.estimate,
        rate = filter.rate,
        bias = filter.bias,
        residual = filter.residual,
        tracking_error = filter.tracking_error,
        control = controller.control,
        integral = controller.integral,
        command_power = controller.command_power,
        saturation = controller.saturation,
        position = plant.position,
        velocity = plant.velocity,
        energy = plant.energy,
        load = plant.load,
        heat = plant.heat,
        dt = plant.dt,
        checksum = audit.checksum,
        risk = audit.risk,
        trend = audit.trend,
        score = audit.score,
    )
end

"""Create an inline process configured for the route-heavy workload."""
function inline_route_process(steps::I) where {I<:Integer}
    return InlineProcess(inline_route_heavy_algorithm(); repeats = steps)
end

"""Measure elapsed time and allocation for inline `run` from entrypoint to completion."""
function inline_route_measure_process(process::IP, runs::I) where {IP<:StatefulAlgorithms.InlineProcess, I<:Integer}
    reset!(process)
    INLINE_ROUTE_HEAVY_SINK[] = run(process)

    GC.gc()
    elapsed_ns = 0
    local elapsed_result = nothing
    for _ in 1:runs
        reset!(process)
        start_ns = time_ns()
        elapsed_result = run(process)
        elapsed_ns += time_ns() - start_ns
    end
    INLINE_ROUTE_HEAVY_SINK[] = elapsed_result

    GC.gc()
    allocated = 0
    local allocated_result = nothing
    for _ in 1:runs
        reset!(process)
        allocated += @allocated begin
            allocated_result = run(process)
        end
    end
    INLINE_ROUTE_HEAVY_SINK[] = allocated_result

    elapsed = elapsed_ns / 1e9
    return (; elapsed, allocated, seconds_per_run = elapsed / runs, bytes_per_run = allocated / runs)
end

"""Measure elapsed time and allocation for the equivalent ordinary loop."""
function inline_route_measure_plain(steps::I, runs::J) where {I<:Integer, J<:Integer}
    INLINE_ROUTE_HEAVY_SINK[] = inline_route_plain_loop(steps)

    GC.gc()
    elapsed = @elapsed begin
        local result = nothing
        for _ in 1:runs
            result = inline_route_plain_loop(steps)
        end
        INLINE_ROUTE_HEAVY_SINK[] = result
    end

    GC.gc()
    allocated = @allocated begin
        local result = nothing
        for _ in 1:runs
            result = inline_route_plain_loop(steps)
        end
        INLINE_ROUTE_HEAVY_SINK[] = result
    end

    return (; elapsed, allocated, seconds_per_run = elapsed / runs, bytes_per_run = allocated / runs)
end

"""Run correctness checks and print inline route-heavy benchmark numbers."""
function run_inline_route_heavy_benchmark(;
    steps::I = INLINE_ROUTE_HEAVY_STEPS,
    runs::J = INLINE_ROUTE_HEAVY_RUNS,
) where {I<:Integer, J<:Integer}
    process = inline_route_process(steps)
    reset!(process)
    route_summary = inline_route_summary(run(process))
    plain_summary = inline_route_plain_loop(steps)

    @testset "inline route-heavy benchmark" begin
        @test keys(route_summary) == keys(plain_summary)
        for key in keys(route_summary)
            @test isapprox(getproperty(route_summary, key), getproperty(plain_summary, key); rtol = 0.0, atol = 1e-12)
        end
    end

    route_measure = inline_route_measure_process(process, runs)
    plain_measure = inline_route_measure_plain(steps, runs)

    println("inline_route_heavy_steps=", steps)
    println("inline_route_heavy_runs=", runs)
    @printf("inline_route_run_seconds_per_run=%.9f\n", route_measure.seconds_per_run)
    @printf("plain_loop_seconds_per_run=%.9f\n", plain_measure.seconds_per_run)
    @printf("seconds_ratio=%.3f\n", route_measure.seconds_per_run / plain_measure.seconds_per_run)
    @printf("inline_route_run_bytes_per_run=%.1f\n", route_measure.bytes_per_run)
    @printf("plain_loop_bytes_per_run=%.1f\n", plain_measure.bytes_per_run)
    @printf("bytes_ratio=%.3f\n", route_measure.bytes_per_run / max(plain_measure.bytes_per_run, 1))
    @printf("final_checksum=%.12f\n", route_summary.checksum)
    @printf("final_position=%.12f\n", route_summary.position)
    @printf("final_score=%.12f\n", route_summary.score)

    return (; route_summary, plain_summary, route_measure, plain_measure)
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_inline_route_heavy_benchmark()
end
