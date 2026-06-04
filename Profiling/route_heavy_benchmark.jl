using StatefulAlgorithms

const ROUTE_HEAVY_STEPS = parse(Int, get(ENV, "ROUTE_HEAVY_STEPS", "400"))
const ROUTE_HEAVY_RUNS = parse(Int, get(ENV, "ROUTE_HEAVY_RUNS", "60"))

struct RouteHeavySource <: StatefulAlgorithms.ProcessAlgorithm end
struct RouteHeavySink{I} <: StatefulAlgorithms.ProcessAlgorithm end

function StatefulAlgorithms.init(::RouteHeavySource, context::C) where {C}
    return (;
        x1 = 1.0, x2 = 2.0, x3 = 3.0, x4 = 4.0,
        x5 = 5.0, x6 = 6.0, x7 = 7.0, x8 = 8.0,
        x9 = 9.0, x10 = 10.0, x11 = 11.0, x12 = 12.0,
    )
end

function StatefulAlgorithms.step!(::RouteHeavySource, context::C) where {C}
    return (;
        x1 = context.x1 + 1.0, x2 = context.x2 + 1.0,
        x3 = context.x3 + 1.0, x4 = context.x4 + 1.0,
        x5 = context.x5 + 1.0, x6 = context.x6 + 1.0,
        x7 = context.x7 + 1.0, x8 = context.x8 + 1.0,
        x9 = context.x9 + 1.0, x10 = context.x10 + 1.0,
        x11 = context.x11 + 1.0, x12 = context.x12 + 1.0,
    )
end

function StatefulAlgorithms.init(::RouteHeavySink{I}, context::C) where {I, C}
    return (; total = 0.0)
end

function StatefulAlgorithms.step!(::RouteHeavySink{I}, context::C) where {I, C}
    total = context.total +
        context.x1 + context.x2 + context.x3 + context.x4 +
        context.x5 + context.x6 + context.x7 + context.x8 +
        context.x9 + context.x10 + context.x11 + context.x12
    return (; total)
end

function route_heavy_algorithm()
    return @CompositeAlgorithm begin
        @alias source = RouteHeavySource
        x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12 = source()

        RouteHeavySink{1}(x1 = x1, x2 = x2, x3 = x3, x4 = x4, x5 = x5, x6 = x6, x7 = x7, x8 = x8, x9 = x9, x10 = x10, x11 = x11, x12 = x12)
        RouteHeavySink{2}(x1 = x1, x2 = x2, x3 = x3, x4 = x4, x5 = x5, x6 = x6, x7 = x7, x8 = x8, x9 = x9, x10 = x10, x11 = x11, x12 = x12)
        RouteHeavySink{3}(x1 = x1, x2 = x2, x3 = x3, x4 = x4, x5 = x5, x6 = x6, x7 = x7, x8 = x8, x9 = x9, x10 = x10, x11 = x11, x12 = x12)
        RouteHeavySink{4}(x1 = x1, x2 = x2, x3 = x3, x4 = x4, x5 = x5, x6 = x6, x7 = x7, x8 = x8, x9 = x9, x10 = x10, x11 = x11, x12 = x12)
        RouteHeavySink{5}(x1 = x1, x2 = x2, x3 = x3, x4 = x4, x5 = x5, x6 = x6, x7 = x7, x8 = x8, x9 = x9, x10 = x10, x11 = x11, x12 = x12)
        RouteHeavySink{6}(x1 = x1, x2 = x2, x3 = x3, x4 = x4, x5 = x5, x6 = x6, x7 = x7, x8 = x8, x9 = x9, x10 = x10, x11 = x11, x12 = x12)
    end
end

function sink_total(result)
    ctx = StatefulAlgorithms.context(result)
    return ctx[RouteHeavySink{1}].total
end

function benchmark_route_heavy(; steps::Int = ROUTE_HEAVY_STEPS, runs::Int = ROUTE_HEAVY_RUNS)
    algo = init(resolve(route_heavy_algorithm()))

    # Warm compilation before timing or allocation measurement.
    warm = run(algo; repeats = steps)
    checksum = sink_total(warm)

    GC.gc()
    elapsed = @elapsed begin
        local total = checksum
        for _ in 1:runs
            total += sink_total(run(algo; repeats = steps))
        end
        checksum = total
    end

    GC.gc()
    allocated = @allocated begin
        local total = checksum
        for _ in 1:runs
            total += sink_total(run(algo; repeats = steps))
        end
        checksum = total
    end

    println("route_heavy_steps=$steps")
    println("route_heavy_runs=$runs")
    println("route_heavy_elapsed_seconds=$elapsed")
    println("route_heavy_allocated_bytes=$allocated")
    println("route_heavy_seconds_per_run=$(elapsed / runs)")
    println("route_heavy_bytes_per_run=$(allocated / runs)")
    println("route_heavy_checksum=$checksum")
end

if abspath(PROGRAM_FILE) == @__FILE__
    benchmark_route_heavy()
end
