using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Printf
using Statistics
using Test
using StatefulAlgorithms

const ROUTINE_ENTRY_SIZE = parse(Int, get(ENV, "ROUTINE_ENTRY_SIZE", "64"))
const ROUTINE_ENTRY_REPEATS = parse(Int, get(ENV, "ROUTINE_ENTRY_REPEATS", "16"))
const ROUTINE_ENTRY_RUNS = parse(Int, get(ENV, "ROUTINE_ENTRY_RUNS", "10"))
const ROUTINE_ENTRY_WARMUPS = parse(Int, get(ENV, "ROUTINE_ENTRY_WARMUPS", "2"))
const ROUTINE_ENTRY_MEASURE_GENERATED = lowercase(get(ENV, "ROUTINE_ENTRY_MEASURE_GENERATED", "true")) in ("1", "true", "yes")
const ROUTINE_ENTRY_EVENTS = Vector{Tuple{Symbol,UInt64}}()

mutable struct RoutineEntryModel{S,F,B}
    state::S
    field::F
    buffer::B
end

struct RoutineEntryDynamics <: StatefulAlgorithms.ProcessAlgorithm end

"""Record a timestamped region marker from inside the synthetic routine body."""
function routine_entry_marker!(label::Symbol)
    push!(ROUTINE_ENTRY_EVENTS, (label, time_ns()))
    return nothing
end

"""Build a mutable model with preallocated buffers used by the routine probe."""
function routine_entry_model(n::Int)
    state = zeros(Float64, n)
    field = zeros(Float64, n)
    buffer = zeros(Float64, n)
    return RoutineEntryModel(state, field, buffer)
end

"""Reset the mutable model state before a free-phase style update."""
function routine_entry_reset!(model::M) where {M<:RoutineEntryModel}
    routine_entry_marker!(:reset)
    fill!(model.state, 0.0)
    fill!(model.buffer, 0.0)
    return model
end

"""Project a small input vector into the model field without allocating buffers."""
function routine_entry_project!(model::M, weights::W, x::X, pattern::P) where {M<:RoutineEntryModel,W<:AbstractVector,X<:AbstractVector,P<:AbstractVector}
    routine_entry_marker!(:project)
    @inbounds for i in eachindex(pattern)
        value = weights[i] * x[i] + 0.25 * sin(x[i] + i * 0.01)
        pattern[i] = value
        model.field[i] = value
    end
    return model
end

"""Advance the model by one small scalar-buffer dynamics step."""
function routine_entry_dynamics!(model::M) where {M<:RoutineEntryModel}
    routine_entry_marker!(:dynamics)
    @inbounds for i in eachindex(model.state)
        left = i == firstindex(model.state) ? lastindex(model.state) : i - 1
        right = i == lastindex(model.state) ? firstindex(model.state) : i + 1
        model.buffer[i] = 0.92 * model.state[i] + 0.04 * (model.state[left] + model.state[right]) + 0.11 * model.field[i]
    end
    model.state, model.buffer = model.buffer, model.state
    return model
end

"""Return the model state vector for use through an explicit DSL `@transform`."""
function routine_entry_state(model::M) where {M<:RoutineEntryModel}
    return model.state
end

"""Copy a routed state vector into the persistent equilibrium buffer."""
function routine_entry_copy!(dest::D, src::S) where {D<:AbstractVector,S<:AbstractVector}
    routine_entry_marker!(:copy)
    copyto!(dest, src)
    return dest
end

"""Initialize the dynamics algorithm with the externally supplied model object."""
function StatefulAlgorithms.init(::RoutineEntryDynamics, context::C) where {C}
    return (; model = context.model)
end

"""Run one dynamics step and return the model so DSL copy-out can route it."""
function StatefulAlgorithms.step!(::RoutineEntryDynamics, context::C) where {C}
    routine_entry_dynamics!(context.model)
    return (; model = context.model)
end

"""Construct the free-phase shaped routine used by the latency probe."""
function routine_entry_algorithm()
    return @Routine begin
        @state x = collect(range(0.05, 0.95; length = ROUTINE_ENTRY_SIZE))
        @state input_hidden_w = collect(range(0.2, 1.1; length = ROUTINE_ENTRY_SIZE))
        @state input_pattern = zeros(Float64, ROUTINE_ENTRY_SIZE)
        @state equilibrium_state = zeros(Float64, ROUTINE_ENTRY_SIZE)
        @alias dynamics = RoutineEntryDynamics()

        routine_entry_reset!(dynamics.model)
        routine_entry_project!(dynamics.model, input_hidden_w, x, input_pattern)
        model = @repeat ROUTINE_ENTRY_REPEATS dynamics()
        routine_entry_copy!(equilibrium_state, @transform(routine_entry_state, model))
    end
end

"""Build the `Process` used by the routine-entry latency probe."""
function routine_entry_process()
    model = routine_entry_model(ROUTINE_ENTRY_SIZE)
    algo = resolve(routine_entry_algorithm())
    process = Process(algo, Init(:dynamics; model); repeat = 1)
    return process, model
end

"""Run the same semantic work directly, outside the StatefulAlgorithms routine loop."""
function routine_entry_direct!(model::M, x::X, weights::W, pattern::P, equilibrium::E) where {M<:RoutineEntryModel,X<:AbstractVector,W<:AbstractVector,P<:AbstractVector,E<:AbstractVector}
    routine_entry_reset!(model)
    routine_entry_project!(model, weights, x, pattern)
    for _ in 1:ROUTINE_ENTRY_REPEATS
        routine_entry_dynamics!(model)
    end
    routine_entry_copy!(equilibrium, routine_entry_state(model))
    return equilibrium
end

"""Return a stable checksum so benchmarked paths cannot be optimized away."""
function routine_entry_checksum(values::V) where {V<:AbstractVector}
    total = 0.0
    @inbounds for i in eachindex(values)
        total += values[i] * (1.0 + 0.001 * i)
    end
    return total
end

"""Measure one evented call and split time around the first and last body markers."""
function routine_entry_measure(callable::F) where {F}
    empty!(ROUTINE_ENTRY_EVENTS)
    start_ns = time_ns()
    result = callable()
    stop_ns = time_ns()
    events = copy(ROUTINE_ENTRY_EVENTS)
    first_marker_ns = isempty(events) ? stop_ns : first(events)[2]
    last_marker_ns = isempty(events) ? start_ns : last(events)[2]
    return (;
        result,
        total = (stop_ns - start_ns) / 1e9,
        entry = (first_marker_ns - start_ns) / 1e9,
        body = (last_marker_ns - first_marker_ns) / 1e9,
        after = (stop_ns - last_marker_ns) / 1e9,
        events = length(events),
        first = isempty(events) ? :none : first(events)[1],
        last = isempty(events) ? :none : last(events)[1],
    )
end

"""Return the median timing fields across a vector of evented measurements."""
function routine_entry_medians(samples::S) where {S<:AbstractVector}
    return (;
        total = median(getfield.(samples, :total)),
        entry = median(getfield.(samples, :entry)),
        body = median(getfield.(samples, :body)),
        after = median(getfield.(samples, :after)),
    )
end

"""Run one direct semantic pass and return the copied equilibrium buffer."""
function routine_entry_direct_call!(model, x, weights, pattern, equilibrium)
    return routine_entry_direct!(model, x, weights, pattern, equilibrium)
end

"""Run one warmed `runprocessinline!` pass after resetting process counters."""
function routine_entry_inline_call!(process::P) where {P<:Process}
    reset!(process)
    StatefulAlgorithms.runprocessinline!(process)
    return context(process)[:_state].equilibrium_state
end

"""Run one explicit loop-type pass to compare generated and non-generated entry."""
function routine_entry_looptype_call!(process::P, looptype::LT) where {P<:Process,LT}
    reset!(process)
    algo = StatefulAlgorithms.getalgo(process)
    base_context = StatefulAlgorithms.context(process)
    lifetime = StatefulAlgorithms.lifetime(process)
    result = StatefulAlgorithms.loop(process, algo, base_context, lifetime, (;), StatefulAlgorithms.Resuming{false}(), looptype)
    result isa StatefulAlgorithms.AbstractContext && StatefulAlgorithms.context(process, result)
    process.loopidx = 1
    return context(process)[:_state].equilibrium_state
end

"""Print one comparable benchmark row for commit-to-commit diagnostics."""
function routine_entry_print_row(label::AbstractString, first_sample, medians, checksum)
    @printf("%s_first_total=%.9f\n", label, first_sample.total)
    @printf("%s_first_entry=%.9f\n", label, first_sample.entry)
    @printf("%s_first_body=%.9f\n", label, first_sample.body)
    @printf("%s_first_after=%.9f\n", label, first_sample.after)
    @printf("%s_first_events=%d\n", label, first_sample.events)
    @printf("%s_first_marker=%s\n", label, string(first_sample.first))
    @printf("%s_last_marker=%s\n", label, string(first_sample.last))
    @printf("%s_warm_total_median=%.9f\n", label, medians.total)
    @printf("%s_warm_entry_median=%.9f\n", label, medians.entry)
    @printf("%s_warm_body_median=%.9f\n", label, medians.body)
    @printf("%s_warm_after_median=%.9f\n", label, medians.after)
    @printf("%s_checksum=%.12f\n", label, checksum)
    return nothing
end

"""Run the routine-entry latency probe."""
function run_routine_entry_latency_probe()
    @printf("routine_entry_size=%d\n", ROUTINE_ENTRY_SIZE)
    @printf("routine_entry_repeats=%d\n", ROUTINE_ENTRY_REPEATS)
    @printf("routine_entry_runs=%d\n", ROUTINE_ENTRY_RUNS)
    @printf("routine_entry_warmups=%d\n", ROUTINE_ENTRY_WARMUPS)

    direct_model = routine_entry_model(ROUTINE_ENTRY_SIZE)
    direct_x = collect(range(0.05, 0.95; length = ROUTINE_ENTRY_SIZE))
    direct_weights = collect(range(0.2, 1.1; length = ROUTINE_ENTRY_SIZE))
    direct_pattern = zeros(Float64, ROUTINE_ENTRY_SIZE)
    direct_equilibrium = zeros(Float64, ROUTINE_ENTRY_SIZE)

    direct_first = routine_entry_measure(() -> routine_entry_direct_call!(direct_model, direct_x, direct_weights, direct_pattern, direct_equilibrium))
    for _ in 1:ROUTINE_ENTRY_WARMUPS
        routine_entry_measure(() -> routine_entry_direct_call!(direct_model, direct_x, direct_weights, direct_pattern, direct_equilibrium))
    end
    direct_samples = [routine_entry_measure(() -> routine_entry_direct_call!(direct_model, direct_x, direct_weights, direct_pattern, direct_equilibrium)) for _ in 1:ROUTINE_ENTRY_RUNS]
    direct_medians = routine_entry_medians(direct_samples)
    direct_checksum = routine_entry_checksum(direct_equilibrium)
    routine_entry_print_row("direct", direct_first, direct_medians, direct_checksum)

    inline_process, _ = routine_entry_process()
    inline_first = routine_entry_measure(() -> routine_entry_inline_call!(inline_process))
    for _ in 1:ROUTINE_ENTRY_WARMUPS
        routine_entry_measure(() -> routine_entry_inline_call!(inline_process))
    end
    inline_samples = [routine_entry_measure(() -> routine_entry_inline_call!(inline_process)) for _ in 1:ROUTINE_ENTRY_RUNS]
    inline_medians = routine_entry_medians(inline_samples)
    inline_checksum = routine_entry_checksum(context(inline_process)[:_state].equilibrium_state)
    routine_entry_print_row("runprocessinline", inline_first, inline_medians, inline_checksum)

    non_generated_process, _ = routine_entry_process()
    non_generated_first = routine_entry_measure(() -> routine_entry_looptype_call!(non_generated_process, StatefulAlgorithms.NonGenerated()))
    for _ in 1:ROUTINE_ENTRY_WARMUPS
        routine_entry_measure(() -> routine_entry_looptype_call!(non_generated_process, StatefulAlgorithms.NonGenerated()))
    end
    non_generated_samples = [routine_entry_measure(() -> routine_entry_looptype_call!(non_generated_process, StatefulAlgorithms.NonGenerated())) for _ in 1:ROUTINE_ENTRY_RUNS]
    non_generated_medians = routine_entry_medians(non_generated_samples)
    non_generated_checksum = routine_entry_checksum(context(non_generated_process)[:_state].equilibrium_state)
    routine_entry_print_row("loop_nongenerated", non_generated_first, non_generated_medians, non_generated_checksum)

    if ROUTINE_ENTRY_MEASURE_GENERATED
        generated_process, _ = routine_entry_process()
        generated_first = routine_entry_measure(() -> routine_entry_looptype_call!(generated_process, StatefulAlgorithms.Generated()))
        for _ in 1:ROUTINE_ENTRY_WARMUPS
            routine_entry_measure(() -> routine_entry_looptype_call!(generated_process, StatefulAlgorithms.Generated()))
        end
        generated_samples = [routine_entry_measure(() -> routine_entry_looptype_call!(generated_process, StatefulAlgorithms.Generated())) for _ in 1:ROUTINE_ENTRY_RUNS]
        generated_medians = routine_entry_medians(generated_samples)
        generated_checksum = routine_entry_checksum(context(generated_process)[:_state].equilibrium_state)
        routine_entry_print_row("loop_generated", generated_first, generated_medians, generated_checksum)
        @test generated_checksum ≈ direct_checksum rtol = 1e-10
    end

    @test inline_checksum ≈ direct_checksum rtol = 1e-10
    @test non_generated_checksum ≈ direct_checksum rtol = 1e-10
    @printf("runprocessinline_to_direct_warm_ratio=%.6f\n", inline_medians.total / direct_medians.total)
    @printf("loop_nongenerated_to_direct_warm_ratio=%.6f\n", non_generated_medians.total / direct_medians.total)
    return nothing
end

run_routine_entry_latency_probe()
