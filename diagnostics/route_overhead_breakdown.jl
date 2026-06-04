using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

include(joinpath(@__DIR__, "route_transparency_diagnostic.jl"))
include(joinpath(@__DIR__, "route_buffer_compat_benchmark.jl"))

const ROUTE_BREAKDOWN_STEPS = parse(Int, get(ENV, "ROUTE_BREAKDOWN_STEPS", "2000"))
const ROUTE_BREAKDOWN_RUNS = parse(Int, get(ENV, "ROUTE_BREAKDOWN_RUNS", "40"))
const ROUTE_BREAKDOWN_SINK = Ref{Any}(nothing)

"""Build the macro-generated routed buffer algorithm without `@context` or `@merge`."""
function macro_route_buffers_no_merge_algorithm()
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
    end
end

"""Build only the explicit merged state-buffer routine section."""
function merge_state_buffer_only_algorithm()
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
        @context ledger_left = ledger_left
        @context ledger_right = ledger_right
        @context ledger_third = ledger_third
        @merge ledger_left.merge_buffer, ledger_right.merge_buffer, ledger_third.merge_buffer
    end
end

"""Build nested state-buffer routines without explicit `@merge`."""
function context_state_buffer_no_merge_algorithm()
    ledger_left = @Routine begin
        @state left_buffer = zeros(Float64, 3)
        left_buffer = diagnostic_merge_buffer!(left_buffer, 0.021, 0.7)
    end

    ledger_right = @Routine begin
        @state right_buffer = zeros(Float64, 3)
        right_buffer = diagnostic_merge_buffer!(right_buffer, 0.034, -0.4)
    end

    ledger_third = @Routine begin
        @state third_buffer = zeros(Float64, 3)
        third_buffer = diagnostic_merge_buffer!(third_buffer, 0.055, 0.25)
    end

    return @CompositeAlgorithm begin
        @context ledger_left = ledger_left
        @context ledger_right = ledger_right
        @context ledger_third = ledger_third
    end
end

"""Return a compact checksum from the macro route-buffer run."""
function macro_route_buffers_summary(result::A) where {A<:StatefulAlgorithms.AbstractLoopAlgorithm}
    ctx = StatefulAlgorithms.context(result)
    plant = ctx[:plant]
    controller = ctx[:controller]
    observer = ctx[:observer]
    return sum(plant.trace) + sum(plant.scratch) + controller.force + observer.checksum
end

"""Return a compact checksum from the merged state-buffer run."""
function merge_state_buffer_summary(result::A) where {A<:StatefulAlgorithms.AbstractLoopAlgorithm}
    ctx = StatefulAlgorithms.context(result)
    return sum(ctx[:_state].merge_buffer)
end

"""Return a compact checksum from the nested non-merged state-buffer run."""
function context_state_buffer_summary(result::A) where {A<:StatefulAlgorithms.AbstractLoopAlgorithm}
    ctx = StatefulAlgorithms.context(result)
    return sum(ctx[:_state].left_buffer) + sum(ctx[:_state].right_buffer) + sum(ctx[:_state].third_buffer)
end

"""Measure elapsed time and allocated bytes for a benchmark closure."""
function breakdown_measure(f::F, runs::I) where {F<:Function, I<:Integer}
    f()
    GC.gc()
    elapsed = @elapsed begin
        local result = nothing
        for _ in 1:runs
            result = f()
        end
        ROUTE_BREAKDOWN_SINK[] = result
    end

    GC.gc()
    allocated = @allocated begin
        local result = nothing
        for _ in 1:runs
            result = f()
        end
        ROUTE_BREAKDOWN_SINK[] = result
    end

    return (; seconds_per_run = elapsed / runs, bytes_per_run = allocated / runs)
end

"""Print a stripped-down allocation/timing breakdown for route overhead."""
function run_route_overhead_breakdown(;
    steps::I = ROUTE_BREAKDOWN_STEPS,
    runs::J = ROUTE_BREAKDOWN_RUNS,
) where {I<:Integer, J<:Integer}
    compat = init(resolve(compat_route_buffer_algorithm()))
    macro_no_merge = init(resolve(macro_route_buffers_no_merge_algorithm()))
    merge_only = init(resolve(merge_state_buffer_only_algorithm()))
    context_only = init(resolve(context_state_buffer_no_merge_algorithm()))
    full = init(resolve(route_transparency_algorithm()))

    measurements = (;
        compat_manual_routes = breakdown_measure(
            () -> compat_route_buffer_summary(run(compat; repeats = steps)).checksum,
            runs,
        ),
        macro_routes_no_merge = breakdown_measure(
            () -> macro_route_buffers_summary(run(macro_no_merge; repeats = steps)),
            runs,
        ),
        merge_state_buffer_only = breakdown_measure(
            () -> merge_state_buffer_summary(run(merge_only; repeats = steps)),
            runs,
        ),
        context_state_buffer_no_merge = breakdown_measure(
            () -> context_state_buffer_summary(run(context_only; repeats = steps)),
            runs,
        ),
        full_route_transparency = breakdown_measure(
            () -> route_transparency_summary(run(full; repeats = steps)).checksum,
            runs,
        ),
        bespoke_buffers = breakdown_measure(
            () -> bespoke_route_transparency_loop(steps).checksum,
            runs,
        ),
    )

    println("route_breakdown_steps=", steps)
    println("route_breakdown_runs=", runs)
    for name in propertynames(measurements)
        m = getproperty(measurements, name)
        println(name, "_seconds_per_run=", m.seconds_per_run)
        println(name, "_bytes_per_run=", m.bytes_per_run)
    end

    return measurements
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_route_overhead_breakdown()
end
