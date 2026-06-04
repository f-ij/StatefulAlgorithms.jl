using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Printf
using Test
using StatefulAlgorithms

const ROUTE_BUFFER_COMPAT_STEPS = parse(Int, get(ENV, "ROUTE_BUFFER_COMPAT_STEPS", "2000"))
const ROUTE_BUFFER_COMPAT_RUNS = parse(Int, get(ENV, "ROUTE_BUFFER_COMPAT_RUNS", "40"))
const ROUTE_BUFFER_COMPAT_SINK = Ref{Any}(nothing)

struct CompatController <: StatefulAlgorithms.ProcessAlgorithm end
struct CompatPlant <: StatefulAlgorithms.ProcessAlgorithm end
struct CompatObserver <: StatefulAlgorithms.ProcessAlgorithm end
struct CompatMirror{MirrorId} <: StatefulAlgorithms.ProcessAlgorithm end

"""Mutate the shared diagnostic buffers with one scalar contribution."""
function compat_touch_buffers!(
    trace::TV,
    scratch::SV,
    tag::I,
    value::T,
) where {T<:AbstractFloat, TV<:AbstractVector{T}, SV<:AbstractVector{T}, I<:Integer}
    trace_index = mod1(tag, length(trace))
    scratch_index = mod1(tag, length(scratch))
    trace[trace_index] = muladd(0.92, trace[trace_index], 0.08 * value)
    scratch[scratch_index] = muladd(0.85, scratch[scratch_index], 0.15 * (value + trace[trace_index]))
    return trace, scratch
end

"""Update the controller state and write through routed buffers."""
function compat_controller_kernel!(
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
    compat_touch_buffers!(trace, scratch, 1, new_force + target)
    return new_force, trace, scratch, control_buffer
end

"""Advance the plant dynamics and write through routed buffers."""
function compat_plant_kernel!(
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
    compat_touch_buffers!(trace, scratch, 2, new_position + new_velocity)
    compat_touch_buffers!(trace, scratch, 3, new_energy + work)
    return new_position, new_velocity, new_energy, trace, scratch
end

"""Update the observer checksum and write through routed buffers."""
function compat_observer_kernel!(
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
    compat_touch_buffers!(trace, scratch, 4, observation + residual)
    return muladd(0.997, checksum, observation + 0.2 * residual + stability), trace, scratch, observer_buffer
end

"""Fold routed state and buffers into one mirror score."""
function compat_mirror_kernel!(
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
    compat_touch_buffers!(trace, scratch, 4 + MirrorId, new_score)
    return new_score, new_samples, trace, scratch, mirror_buffer
end

"""Initialize controller-local state."""
function StatefulAlgorithms.init(::CompatController, context::C) where {C}
    return (; force = 0.0, control_buffer = zeros(Float64, 4))
end

"""Step the controller and return local plus routed buffer names."""
function StatefulAlgorithms.step!(::CompatController, context::C) where {C}
    force, trace, scratch, control_buffer = compat_controller_kernel!(
        context.trace,
        context.scratch,
        context.control_buffer,
        context.position,
        context.velocity,
        context.energy,
        context.force,
    )
    return (; force, trace, scratch, control_buffer)
end

"""Initialize plant-local state and the routed buffers."""
function StatefulAlgorithms.init(::CompatPlant, context::C) where {C}
    return (;
        position = 0.25,
        velocity = -0.15,
        energy = 0.35,
        trace = zeros(Float64, 8),
        scratch = zeros(Float64, 5),
        dt = 0.025,
    )
end

"""Step the plant and return local plus routed buffer names."""
function StatefulAlgorithms.step!(::CompatPlant, context::C) where {C}
    position, velocity, energy, trace, scratch = compat_plant_kernel!(
        context.trace,
        context.scratch,
        context.position,
        context.velocity,
        context.energy,
        context.force,
        context.dt,
    )
    return (; position, velocity, energy, trace, scratch, dt = context.dt)
end

"""Initialize observer-local state."""
function StatefulAlgorithms.init(::CompatObserver, context::C) where {C}
    return (; checksum = 0.0, observer_buffer = zeros(Float64, 3))
end

"""Step the observer and return local plus routed buffer names."""
function StatefulAlgorithms.step!(::CompatObserver, context::C) where {C}
    checksum, trace, scratch, observer_buffer = compat_observer_kernel!(
        context.trace,
        context.scratch,
        context.observer_buffer,
        context.position,
        context.velocity,
        context.energy,
        context.force,
        context.checksum,
    )
    return (; checksum, trace, scratch, observer_buffer)
end

"""Initialize mirror-local state."""
function StatefulAlgorithms.init(::CompatMirror{MirrorId}, context::C) where {MirrorId, C}
    return (; score = 0.0, samples = 0, mirror_buffer = zeros(Float64, 3))
end

"""Step one mirror and return local plus routed buffer names."""
function StatefulAlgorithms.step!(::CompatMirror{MirrorId}, context::C) where {MirrorId, C}
    score, samples, trace, scratch, mirror_buffer = compat_mirror_kernel!(
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

"""Build the compatibility routed buffer algorithm."""
function compat_route_buffer_algorithm()
    return @CompositeAlgorithm begin
        @alias plant = CompatPlant()
        @alias controller = CompatController()
        @alias observer = CompatObserver()

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
        CompatMirror{1}(
            position = plant.position,
            velocity = plant.velocity,
            energy = plant.energy,
            force = controller.force,
            checksum = observer.checksum,
            trace = plant.trace,
            scratch = plant.scratch,
        )
        CompatMirror{2}(
            position = plant.position,
            velocity = plant.velocity,
            energy = plant.energy,
            force = controller.force,
            checksum = observer.checksum,
            trace = plant.trace,
            scratch = plant.scratch,
        )
        CompatMirror{3}(
            position = plant.position,
            velocity = plant.velocity,
            energy = plant.energy,
            force = controller.force,
            checksum = observer.checksum,
            trace = plant.trace,
            scratch = plant.scratch,
        )
    end
end

"""Run the equivalent workload in one ordinary outer loop."""
function compat_bespoke_loop(steps::I) where {I<:Integer}
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

    for _ in 1:steps
        force, trace, scratch, control_buffer = compat_controller_kernel!(
            trace, scratch, control_buffer, position, velocity, energy, force,
        )
        position, velocity, energy, trace, scratch = compat_plant_kernel!(
            trace, scratch, position, velocity, energy, force, dt,
        )
        checksum, trace, scratch, observer_buffer = compat_observer_kernel!(
            trace, scratch, observer_buffer, position, velocity, energy, force, checksum,
        )
        score1, samples1, trace, scratch, mirror_buffer1 = compat_mirror_kernel!(
            trace, scratch, mirror_buffers[1], position, velocity, energy, force, checksum,
            mirror_scores[1], mirror_samples[1], Val(1),
        )
        score2, samples2, trace, scratch, mirror_buffer2 = compat_mirror_kernel!(
            trace, scratch, mirror_buffers[2], position, velocity, energy, force, checksum,
            mirror_scores[2], mirror_samples[2], Val(2),
        )
        score3, samples3, trace, scratch, mirror_buffer3 = compat_mirror_kernel!(
            trace, scratch, mirror_buffers[3], position, velocity, energy, force, checksum,
            mirror_scores[3], mirror_samples[3], Val(3),
        )
        mirror_scores = (score1, score2, score3)
        mirror_samples = (samples1, samples2, samples3)
        mirror_buffers = (mirror_buffer1, mirror_buffer2, mirror_buffer3)
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
    )
end

"""Extract comparable output from a routed run."""
function compat_route_buffer_summary(result::A) where {A<:StatefulAlgorithms.AbstractLoopAlgorithm}
    ctx = StatefulAlgorithms.context(result)
    plant = ctx[:plant]
    controller = ctx[:controller]
    observer = ctx[:observer]
    mirror1 = ctx[CompatMirror{1}]
    mirror2 = ctx[CompatMirror{2}]
    mirror3 = ctx[CompatMirror{3}]

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
    )
end

"""Measure elapsed time and allocation for repeated calls."""
function compat_measure(f::F, runs::I) where {F<:Function, I<:Integer}
    f()
    GC.gc()
    elapsed = @elapsed begin
        local result = nothing
        for _ in 1:runs
            result = f()
        end
        ROUTE_BUFFER_COMPAT_SINK[] = result
    end

    GC.gc()
    allocated = @allocated begin
        local result = nothing
        for _ in 1:runs
            result = f()
        end
        ROUTE_BUFFER_COMPAT_SINK[] = result
    end

    return (; elapsed, allocated, seconds_per_run = elapsed / runs, bytes_per_run = allocated / runs)
end

"""Run the routed-buffer compatibility benchmark."""
function run_route_buffer_compat_benchmark(;
    steps::I = ROUTE_BUFFER_COMPAT_STEPS,
    runs::J = ROUTE_BUFFER_COMPAT_RUNS,
) where {I<:Integer, J<:Integer}
    routed = init(resolve(compat_route_buffer_algorithm()))
    route_summary = compat_route_buffer_summary(run(routed; repeats = steps))
    bespoke_summary = compat_bespoke_loop(steps)

    @testset "route buffer compatibility benchmark" begin
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
    end

    route_measure = compat_measure(() -> compat_route_buffer_summary(run(routed; repeats = steps)), runs)
    bespoke_measure = compat_measure(() -> compat_bespoke_loop(steps), runs)

    println("route_buffer_compat_steps=", steps)
    println("route_buffer_compat_runs=", runs)
    @printf("route_seconds_per_run=%.9f\n", route_measure.seconds_per_run)
    @printf("bespoke_seconds_per_run=%.9f\n", bespoke_measure.seconds_per_run)
    @printf("seconds_ratio=%.3f\n", route_measure.seconds_per_run / bespoke_measure.seconds_per_run)
    @printf("route_bytes_per_run=%.1f\n", route_measure.bytes_per_run)
    @printf("bespoke_bytes_per_run=%.1f\n", bespoke_measure.bytes_per_run)
    @printf("bytes_ratio=%.3f\n", route_measure.bytes_per_run / max(bespoke_measure.bytes_per_run, 1))
    @printf("final_checksum=%.12f\n", route_summary.checksum)
    @printf("final_trace_sum=%.12f\n", sum(route_summary.trace))
    return (; route_summary, bespoke_summary, route_measure, bespoke_measure)
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_route_buffer_compat_benchmark()
end
