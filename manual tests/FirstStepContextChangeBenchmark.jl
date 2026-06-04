include("_env.jl")

"""
Manual benchmark for a tiny routed late-allocation case.

Pattern:
- `ScalarProducer` returns a routed scalar `source`.
- `LateScalarConsumer` reads that routed value as `input_source` and returns its own
  `derived` variable, which is not present in `init`.

The stable control is identical except `StableScalarConsumer` preallocates `derived` in
`init`, so the context shape never changes during `step!`.

This benchmark intentionally does almost no numeric work so that orchestration overhead
and loop-carried type instability matter more than raw arithmetic.
"""

struct ScalarProducer <: StatefulAlgorithms.ProcessAlgorithm end
struct StableScalarConsumer <: StatefulAlgorithms.ProcessAlgorithm end
struct LateScalarConsumer <: StatefulAlgorithms.ProcessAlgorithm end

function StatefulAlgorithms.init(::ScalarProducer, context)
    return (; tick = 0, scale = context.scale, source = 0.0)
end

function StatefulAlgorithms.init(::StableScalarConsumer, _context)
    return (; tick = 0, accum = 0.0, derived = 0.0)
end

function StatefulAlgorithms.init(::LateScalarConsumer, _context)
    return (; tick = 0, accum = 0.0)
end

function StatefulAlgorithms.step!(::ScalarProducer, context::C) where C
    tick = context.tick + 1
    source = muladd(context.scale, tick, context.source)
    return (; tick, source)
end

function StatefulAlgorithms.step!(::StableScalarConsumer, context::C) where C
    tick = context.tick + 1
    derived = muladd(0.5, context.input_source, 0.001 * tick)
    accum = context.accum + derived
    return (; tick, accum, derived)
end

function StatefulAlgorithms.step!(::LateScalarConsumer, context::C) where C
    tick = context.tick + 1
    derived = muladd(0.5, context.input_source, 0.001 * tick)
    accum = context.accum + derived
    return (; tick, accum, derived)
end

const StableScalarGraph = CompositeAlgorithm(
    ScalarProducer,
    StableScalarConsumer,
    (1, 1),
    Route(ScalarProducer => StableScalarConsumer, :source => :input_source),
)

const LateScalarGraph = CompositeAlgorithm(
    ScalarProducer,
    LateScalarConsumer,
    (1, 1),
    Route(ScalarProducer => LateScalarConsumer, :source => :input_source),
)

function run_once(algo; repeats = 2_000_000, scale = 0.001)
    p = Process(
        algo,
        Input(ScalarProducer; scale);
        lifetime = repeats,
    )

    elapsed = @elapsed begin
        run(p)
        wait(p)
    end

    ctx = fetch(p)
    quit(p)

    return elapsed, ctx
end

function benchmark(algo; repeats = 2_000_0000, trials = 5, scale = 0.001, label = string(nameof(typeof(algo))))
    times = Float64[]
    final_ctx = nothing

    run_once(algo; repeats = 1, scale)
    GC.gc()

    for trial in 1:trials
        elapsed, ctx = run_once(algo; repeats, scale)
        push!(times, elapsed)
        final_ctx = ctx
        GC.gc()
        println(label, " trial ", trial, ": ", round(elapsed; digits = 4), " s")
    end

    return times, final_ctx
end

function main(; repeats = 2_000_000, trials = 5, scale = 0.001)
    println("repeats: ", repeats)
    println("trials: ", trials)
    println("scale: ", scale)
    println()

    println("Running stable routed benchmark")
    stable_times, stable_ctx = benchmark(
        StableScalarGraph;
        repeats,
        trials,
        scale,
        label = "StableScalarGraph",
    )
    println()
    println("Stable best: ", round(minimum(stable_times); digits = 4), " s")
    println("Stable producer source: ", round(stable_ctx[ScalarProducer].source; digits = 6))
    println("Stable consumer accum: ", round(stable_ctx[StableScalarConsumer].accum; digits = 6))
    println()

    println("Running late-growth routed benchmark")
    late_times, late_ctx = benchmark(
        LateScalarGraph;
        repeats,
        trials,
        scale,
        label = "LateScalarGraph",
    )
    println()
    println("Late best: ", round(minimum(late_times); digits = 4), " s")
    println("Late producer source: ", round(late_ctx[ScalarProducer].source; digits = 6))
    println("Late consumer accum: ", round(late_ctx[LateScalarConsumer].accum; digits = 6))
    println("Late / Stable: ", round(minimum(late_times) / minimum(stable_times); digits = 3), "x")
end

main()


# TESTS

p = Process(
    StableScalarGraph,
    Input(ScalarProducer; scale = 0.001);
    lifetime = 30,
)
c = context(p)
algo = getalgo(p.taskdata)
@code_warntype StatefulAlgorithms.generated_processloop(p, algo, c, StatefulAlgorithms.lifetime(p))
nc = StatefulAlgorithms.generated_processloop(p, algo, c, StatefulAlgorithms.lifetime(p))
