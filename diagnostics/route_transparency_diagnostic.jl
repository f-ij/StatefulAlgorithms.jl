using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Printf
using Test
using StatefulAlgorithms

const ROUTE_TRANSPARENCY_STEPS = parse(Int, get(ENV, "ROUTE_TRANSPARENCY_STEPS", "2000"))
const ROUTE_TRANSPARENCY_RUNS = parse(Int, get(ENV, "ROUTE_TRANSPARENCY_RUNS", "40"))
const ROUTE_TRANSPARENCY_SINK = Ref{Any}(nothing)

"""Update two shared buffers with one tagged scalar contribution."""
function diagnostic_touch_buffers!(
    trace::TV,
    scratch::SV,
    tag::I,
    value::T,
) where {T<:AbstractFloat, TV<:AbstractVector{T}, SV<:AbstractVector{T}, I<:Integer}
    trace_index = mod1(tag, length(trace))
    scratch_index = mod1(tag, length(scratch))

    # The buffer work is intentionally small, but it mutates routed storage.
    trace[trace_index] = muladd(0.92, trace[trace_index], 0.08 * value)
    scratch[scratch_index] = muladd(0.85, scratch[scratch_index], 0.15 * (value + trace[trace_index]))
    return trace, scratch
end

"""Compute the controller update and write its contribution into routed buffers."""
function diagnostic_controller_kernel!(
    trace::TV,
    scratch::SV,
    control_buffer::CV,
    position::T,
    velocity::T,
    energy::T,
    force::T,
) where {T<:AbstractFloat, TV<:AbstractVector{T}, SV<:AbstractVector{T}, CV<:AbstractVector{T}}
    target = 0.7 * sin(position + 0.3 * energy)
    new_force = muladd(0.64, force, 0.36 * (target - position) - 0.08 * velocity)
    control_buffer[1] = target
    control_buffer[2] = new_force
    control_buffer[3] = muladd(0.97, control_buffer[3], 0.03 * abs(velocity))
    control_buffer[4] = muladd(0.99, control_buffer[4], 0.01 * energy)
    diagnostic_touch_buffers!(trace, scratch, 1, new_force + target)
    return new_force, trace, scratch, control_buffer
end

"""Advance the mock dynamics and write plant-owned buffers."""
function diagnostic_plant_kernel!(
    trace::TV,
    scratch::SV,
    position::T,
    velocity::T,
    energy::T,
    force::T,
    dt::T,
) where {T<:AbstractFloat, TV<:AbstractVector{T}, SV<:AbstractVector{T}}
    acceleration = force - 0.17 * velocity - 0.41 * position + 0.03 * sin(energy + position)
    new_velocity = velocity + dt * acceleration
    new_position = position + dt * new_velocity
    work = force * (new_position - position)
    new_energy = 0.985 * energy + 0.5 * (new_position^2 + new_velocity^2) + 0.04 * abs(work)

    # The routed buffers carry both smoothed state and per-step scratch data.
    diagnostic_touch_buffers!(trace, scratch, 2, new_position + new_velocity)
    diagnostic_touch_buffers!(trace, scratch, 3, new_energy + work)
    return new_position, new_velocity, new_energy, trace, scratch
end

"""Observe the current state, mutate routed buffers, and update a checksum."""
function diagnostic_observer_kernel!(
    trace::TV,
    scratch::SV,
    observer_buffer::OV,
    position::T,
    velocity::T,
    energy::T,
    force::T,
    checksum::T,
) where {T<:AbstractFloat, TV<:AbstractVector{T}, SV<:AbstractVector{T}, OV<:AbstractVector{T}}
    observation = position + 0.11 * velocity + 0.025 * sin(energy)
    residual = force - observation
    stability = inv(1 + abs(residual) + abs(velocity))

    observer_buffer[1] = observation
    observer_buffer[2] = residual
    observer_buffer[3] = stability
    diagnostic_touch_buffers!(trace, scratch, 4, observation + residual)
    new_checksum = muladd(0.997, checksum, observation + 0.2 * residual + stability)
    return new_checksum, trace, scratch, observer_buffer
end

"""Fold the routed state and buffers into one mirror score."""
function diagnostic_mirror_kernel!(
    trace::TV,
    scratch::SV,
    mirror_buffer::MV,
    position::T,
    velocity::T,
    energy::T,
    force::T,
    checksum::T,
    score::T,
    samples::I,
    ::Val{MirrorId},
) where {T<:AbstractFloat, TV<:AbstractVector{T}, SV<:AbstractVector{T}, MV<:AbstractVector{T}, I<:Integer, MirrorId}
    weight = T(MirrorId) * T(0.03125)
    trace_sum = sum(trace)
    scratch_sum = sum(scratch)
    contribution = position + weight * velocity + 0.01 * energy + 0.02 * force + 0.001 * checksum
    new_score = muladd(0.991, score, contribution + 0.0005 * (trace_sum + scratch_sum))
    new_samples = samples + one(I)

    mirror_buffer[1] = new_score
    mirror_buffer[2] = trace_sum
    mirror_buffer[3] = scratch_sum
    diagnostic_touch_buffers!(trace, scratch, 4 + MirrorId, new_score)
    return new_score, new_samples, trace, scratch, mirror_buffer
end

"""Mutate one explicitly merged state buffer used to cover `@merge`."""
function diagnostic_merge_buffer!(
    merge_buffer::BV,
    rate::T,
    weight::T,
) where {T<:AbstractFloat, BV<:AbstractVector{T}}
    merge_buffer[1] += rate
    merge_buffer[2] = muladd(T(0.999), merge_buffer[2], weight * sin(merge_buffer[1]))
    merge_buffer[3] = muladd(T(0.975), merge_buffer[3], abs(weight) + abs(merge_buffer[2]))
    return merge_buffer
end

# Controller process that returns initialized local fields plus routed buffers.
@ProcessAlgorithm function RouteDiagnosticController(
    position,
    velocity,
    energy,
    trace,
    scratch,
    @managed(force = 0.0),
    @managed(control_buffer = zeros(Float64, 4)),
)
    force, trace, scratch, control_buffer = diagnostic_controller_kernel!(
        trace,
        scratch,
        control_buffer,
        position,
        velocity,
        energy,
        force,
    )
    return (; force, trace, scratch, control_buffer)
end

# Plant process that owns the main dynamics state and routed buffers.
@ProcessAlgorithm function RouteDiagnosticPlant(
    force,
    @managed(position = 0.25),
    @managed(velocity = -0.15),
    @managed(energy = 0.35),
    @managed(trace = zeros(Float64, 8)),
    @managed(scratch = zeros(Float64, 5)),
    @managed(dt = 0.025),
)
    position, velocity, energy, trace, scratch = diagnostic_plant_kernel!(
        trace,
        scratch,
        position,
        velocity,
        energy,
        force,
        dt,
    )
    return (; position, velocity, energy, trace, scratch, dt)
end

# Observer process that writes a checksum and returns routed buffers.
@ProcessAlgorithm function RouteDiagnosticObserver(
    position,
    velocity,
    energy,
    force,
    trace,
    scratch,
    @managed(checksum = 0.0),
    @managed(observer_buffer = zeros(Float64, 3)),
)
    checksum, trace, scratch, observer_buffer = diagnostic_observer_kernel!(
        trace,
        scratch,
        observer_buffer,
        position,
        velocity,
        energy,
        force,
        checksum,
    )
    return (; checksum, trace, scratch, observer_buffer)
end

@doc "Controller process that returns initialized local fields plus routed buffers." RouteDiagnosticController
@doc "Plant process that owns the main dynamics state and routed buffers." RouteDiagnosticPlant
@doc "Observer process that writes a checksum and returns routed buffers." RouteDiagnosticObserver

"""Mirror process used several times to fan routed buffers into multiple writers."""
struct RouteDiagnosticMirror{MirrorId} <: StatefulAlgorithms.ProcessAlgorithm end

"""Initialize the mirror's local score storage."""
function StatefulAlgorithms.init(::RouteDiagnosticMirror{MirrorId}, context::C) where {MirrorId, C}
    return (; score = 0.0, samples = 0, mirror_buffer = zeros(Float64, 3))
end

"""Update one mirror and return both local fields and routed buffers."""
function StatefulAlgorithms.step!(::RouteDiagnosticMirror{MirrorId}, context::C) where {MirrorId, C}
    score, samples, trace, scratch, mirror_buffer = diagnostic_mirror_kernel!(
        context.trace,
        context.scratch,
        context.mirror_buffer,
        context.position,
        context.velocity,
        context.energy,
        context.force,
        context.checksum,
        context.score,
        context.samples,
        Val(MirrorId),
    )
    return (; score, samples, trace, scratch, mirror_buffer)
end

"""Build the routed algorithm used by the diagnostic."""
function route_transparency_algorithm()
    ledger_left = @Routine begin
        @state merge_buffer = zeros(Float64, 3)
        merge_buffer = diagnostic_merge_buffer!(merge_buffer, 0.021, 0.7)
    end

    ledger_right = @Routine begin
        @state merge_buffer
        merge_buffer = diagnostic_merge_buffer!(merge_buffer, 0.034, -0.4)
    end

    ledger_third = @Routine begin
        @state merge_buffer
        merge_buffer = diagnostic_merge_buffer!(merge_buffer, 0.055, 0.25)
    end

    return @CompositeAlgorithm begin
        @alias plant = RouteDiagnosticPlant()
        @alias controller = RouteDiagnosticController()
        @alias observer = RouteDiagnosticObserver()

        controller(
            position = plant.position,
            velocity = plant.velocity,
            energy = plant.energy,
            trace = plant.trace,
            scratch = plant.scratch,
        )
        plant(force = controller.force)
        observer(
            position = plant.position,
            velocity = plant.velocity,
            energy = plant.energy,
            force = controller.force,
            trace = plant.trace,
            scratch = plant.scratch,
        )
        RouteDiagnosticMirror{1}(
            position = plant.position,
            velocity = plant.velocity,
            energy = plant.energy,
            force = controller.force,
            checksum = observer.checksum,
            trace = plant.trace,
            scratch = plant.scratch,
        )
        RouteDiagnosticMirror{2}(
            position = plant.position,
            velocity = plant.velocity,
            energy = plant.energy,
            force = controller.force,
            checksum = observer.checksum,
            trace = plant.trace,
            scratch = plant.scratch,
        )
        RouteDiagnosticMirror{3}(
            position = plant.position,
            velocity = plant.velocity,
            energy = plant.energy,
            force = controller.force,
            checksum = observer.checksum,
            trace = plant.trace,
            scratch = plant.scratch,
        )

        @context ledger_left = ledger_left
        @context ledger_right = ledger_right
        @context ledger_third = ledger_third
        @merge ledger_left.merge_buffer, ledger_right.merge_buffer, ledger_third.merge_buffer
    end
end

"""Run the equivalent workload as ordinary function calls in one loop."""
function bespoke_route_transparency_loop(steps::I) where {I<:Integer}
    position = 0.25
    velocity = -0.15
    energy = 0.35
    dt = 0.025
    force = 0.0
    checksum = 0.0
    trace = zeros(Float64, 8)
    scratch = zeros(Float64, 5)
    control_buffer = zeros(Float64, 4)
    observer_buffer = zeros(Float64, 3)
    mirror_buffers = (zeros(Float64, 3), zeros(Float64, 3), zeros(Float64, 3))
    mirror_scores = (0.0, 0.0, 0.0)
    mirror_samples = (0, 0, 0)
    merge_buffer = zeros(Float64, 3)

    # The call order mirrors the routed CompositeAlgorithm statement order.
    for _ in 1:steps
        force, trace, scratch, control_buffer = diagnostic_controller_kernel!(
            trace,
            scratch,
            control_buffer,
            position,
            velocity,
            energy,
            force,
        )
        position, velocity, energy, trace, scratch = diagnostic_plant_kernel!(
            trace,
            scratch,
            position,
            velocity,
            energy,
            force,
            dt,
        )
        checksum, trace, scratch, observer_buffer = diagnostic_observer_kernel!(
            trace,
            scratch,
            observer_buffer,
            position,
            velocity,
            energy,
            force,
            checksum,
        )

        score1, samples1, trace, scratch, mirror_buffer1 = diagnostic_mirror_kernel!(
            trace, scratch, mirror_buffers[1], position, velocity, energy, force, checksum,
            mirror_scores[1], mirror_samples[1], Val(1),
        )
        score2, samples2, trace, scratch, mirror_buffer2 = diagnostic_mirror_kernel!(
            trace, scratch, mirror_buffers[2], position, velocity, energy, force, checksum,
            mirror_scores[2], mirror_samples[2], Val(2),
        )
        score3, samples3, trace, scratch, mirror_buffer3 = diagnostic_mirror_kernel!(
            trace, scratch, mirror_buffers[3], position, velocity, energy, force, checksum,
            mirror_scores[3], mirror_samples[3], Val(3),
        )
        mirror_scores = (score1, score2, score3)
        mirror_samples = (samples1, samples2, samples3)
        mirror_buffers = (mirror_buffer1, mirror_buffer2, mirror_buffer3)

        merge_buffer = diagnostic_merge_buffer!(merge_buffer, 0.021, 0.7)
        merge_buffer = diagnostic_merge_buffer!(merge_buffer, 0.034, -0.4)
        merge_buffer = diagnostic_merge_buffer!(merge_buffer, 0.055, 0.25)
    end

    return (;
        position,
        velocity,
        energy,
        force,
        checksum,
        trace = copy(trace),
        scratch = copy(scratch),
        control_buffer = copy(control_buffer),
        observer_buffer = copy(observer_buffer),
        mirror_scores,
        mirror_samples,
        mirror_buffers = map(copy, mirror_buffers),
        merge_buffer = copy(merge_buffer),
    )
end

"""Extract a compact comparable summary from a routed run result."""
function route_transparency_summary(result::A) where {A<:StatefulAlgorithms.AbstractLoopAlgorithm}
    ctx = StatefulAlgorithms.context(result)
    state = ctx[:_state]
    plant = ctx[:plant]
    controller = ctx[:controller]
    observer = ctx[:observer]
    mirror1 = ctx[RouteDiagnosticMirror{1}]
    mirror2 = ctx[RouteDiagnosticMirror{2}]
    mirror3 = ctx[RouteDiagnosticMirror{3}]

    return (;
        position = plant.position,
        velocity = plant.velocity,
        energy = plant.energy,
        force = controller.force,
        checksum = observer.checksum,
        trace = copy(plant.trace),
        scratch = copy(plant.scratch),
        control_buffer = copy(controller.control_buffer),
        observer_buffer = copy(observer.observer_buffer),
        mirror_scores = (mirror1.score, mirror2.score, mirror3.score),
        mirror_samples = (mirror1.samples, mirror2.samples, mirror3.samples),
        mirror_buffers = (copy(mirror1.mirror_buffer), copy(mirror2.mirror_buffer), copy(mirror3.mirror_buffer)),
        merge_buffer = copy(state.merge_buffer),
    )
end

"""Measure elapsed time and allocated bytes for a repeated diagnostic workload."""
function diagnostic_measure(f::F, runs::I) where {F<:Function, I<:Integer}
    f()
    GC.gc()
    elapsed = @elapsed begin
        local result = nothing
        for _ in 1:runs
            result = f()
        end
        ROUTE_TRANSPARENCY_SINK[] = result
    end

    GC.gc()
    allocated = @allocated begin
        local result = nothing
        for _ in 1:runs
            result = f()
        end
        ROUTE_TRANSPARENCY_SINK[] = result
    end

    return (; elapsed, allocated, seconds_per_run = elapsed / runs, bytes_per_run = allocated / runs)
end

"""Run correctness checks and print route-vs-bespoke diagnostic numbers."""
function run_route_transparency_diagnostic(;
    steps::I = ROUTE_TRANSPARENCY_STEPS,
    runs::J = ROUTE_TRANSPARENCY_RUNS,
) where {I<:Integer, J<:Integer}
    routed = init(resolve(route_transparency_algorithm()))

    route_summary = route_transparency_summary(run(routed; repeats = steps))
    bespoke_summary = bespoke_route_transparency_loop(steps)

    @testset "route transparency diagnostic" begin
        @test isapprox(route_summary.position, bespoke_summary.position; rtol = 0.0, atol = 1e-12)
        @test isapprox(route_summary.velocity, bespoke_summary.velocity; rtol = 0.0, atol = 1e-12)
        @test isapprox(route_summary.energy, bespoke_summary.energy; rtol = 0.0, atol = 1e-12)
        @test isapprox(route_summary.force, bespoke_summary.force; rtol = 0.0, atol = 1e-12)
        @test isapprox(route_summary.checksum, bespoke_summary.checksum; rtol = 0.0, atol = 1e-12)
        @test isapprox(route_summary.trace, bespoke_summary.trace; rtol = 0.0, atol = 1e-12)
        @test isapprox(route_summary.scratch, bespoke_summary.scratch; rtol = 0.0, atol = 1e-12)
        @test isapprox(route_summary.control_buffer, bespoke_summary.control_buffer; rtol = 0.0, atol = 1e-12)
        @test isapprox(route_summary.observer_buffer, bespoke_summary.observer_buffer; rtol = 0.0, atol = 1e-12)
        @test all(isapprox.(route_summary.mirror_scores, bespoke_summary.mirror_scores; rtol = 0.0, atol = 1e-12))
        @test route_summary.mirror_samples == bespoke_summary.mirror_samples
        @test all(
            pair -> isapprox(pair[1], pair[2]; rtol = 0.0, atol = 1e-12),
            zip(route_summary.mirror_buffers, bespoke_summary.mirror_buffers),
        )
        @test isapprox(route_summary.merge_buffer, bespoke_summary.merge_buffer; rtol = 0.0, atol = 1e-12)
    end

    route_measure = diagnostic_measure(() -> route_transparency_summary(run(routed; repeats = steps)), runs)
    bespoke_measure = diagnostic_measure(() -> bespoke_route_transparency_loop(steps), runs)

    println("route_transparency_steps=", steps)
    println("route_transparency_runs=", runs)
    @printf("route_seconds_per_run=%.9f\n", route_measure.seconds_per_run)
    @printf("bespoke_seconds_per_run=%.9f\n", bespoke_measure.seconds_per_run)
    @printf("seconds_ratio=%.3f\n", route_measure.seconds_per_run / bespoke_measure.seconds_per_run)
    @printf("route_bytes_per_run=%.1f\n", route_measure.bytes_per_run)
    @printf("bespoke_bytes_per_run=%.1f\n", bespoke_measure.bytes_per_run)
    @printf("bytes_ratio=%.3f\n", route_measure.bytes_per_run / max(bespoke_measure.bytes_per_run, 1))
    @printf("final_checksum=%.12f\n", route_summary.checksum)
    @printf("final_trace_sum=%.12f\n", sum(route_summary.trace))
    @printf("final_merge_buffer_sum=%.12f\n", sum(route_summary.merge_buffer))

    return (; route_summary, bespoke_summary, route_measure, bespoke_measure)
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_route_transparency_diagnostic()
end
