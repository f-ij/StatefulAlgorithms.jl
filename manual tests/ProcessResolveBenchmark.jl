include("_env.jl")

const PRB_TRIALS = parse(Int, get(ENV, "PROCESSES_RESOLVE_TRIALS", "3"))
const PRB_HOT_RESOLVES = parse(Int, get(ENV, "PROCESSES_RESOLVE_HOT_RUNS", "1000"))

struct ResolveBenchCounter <: ProcessAlgorithm end
struct ResolveBenchScaler <: ProcessAlgorithm end
struct ResolveBenchSink <: ProcessAlgorithm end
struct ResolveBenchVectorPush <: ProcessAlgorithm end
struct ResolveBenchSharedReader <: ProcessAlgorithm end

function StatefulAlgorithms.init(::ResolveBenchCounter, context)
    value = get(context, :value, 0)
    total = get(context, :total, 0)
    return (; value, total)
end

function StatefulAlgorithms.step!(::ResolveBenchCounter, context)
    value = context.value + 1
    return (; value, total = context.total + value)
end

function StatefulAlgorithms.init(::ResolveBenchScaler, context)
    factor = get(context, :factor, 2)
    scaled = get(context, :scaled, 0)
    return (; factor, scaled)
end

function StatefulAlgorithms.step!(::ResolveBenchScaler, context)
    return (; scaled = context.scaled + context.factor)
end

function StatefulAlgorithms.init(::ResolveBenchSink, context)
    return (; seen = get(context, :seen, 0))
end

function StatefulAlgorithms.step!(::ResolveBenchSink, context)
    return (; seen = context.seen + context.value)
end

function StatefulAlgorithms.init(::ResolveBenchVectorPush, context)
    values = Float64[]
    StatefulAlgorithms.processsizehint!(values, context)
    return (; values, source = get(context, :source, 0.0))
end

function StatefulAlgorithms.step!(::ResolveBenchVectorPush, context)
    push!(context.values, context.source)
    return (;)
end

function StatefulAlgorithms.init(::ResolveBenchSharedReader, context)
    return (; total = 0.0)
end

function StatefulAlgorithms.step!(::ResolveBenchSharedReader, context)
    return (; total = context.total + context.source)
end

function resolve_bench_simple()
    return CompositeAlgorithm(ResolveBenchCounter)
end

function resolve_bench_routed()
    return CompositeAlgorithm(
        :counter => ResolveBenchCounter,
        :scaler => ResolveBenchScaler,
        (1, 2),
        Route(ResolveBenchCounter => ResolveBenchScaler, :total => :factor),
    )
end

function resolve_bench_shared()
    return CompositeAlgorithm(
        :writer => ResolveBenchVectorPush,
        :reader => ResolveBenchSharedReader,
        (1, 1),
        Share(ResolveBenchVectorPush, ResolveBenchSharedReader),
    )
end

function resolve_bench_nested()
    inner = CompositeAlgorithm(
        ResolveBenchCounter,
        ResolveBenchScaler,
        (1, 2),
        Route(ResolveBenchCounter => ResolveBenchScaler, :total => :factor),
    )
    return Routine(inner, ResolveBenchSink, (2, 1), Route(ResolveBenchScaler => ResolveBenchSink, :scaled => :value))
end

const RESOLVE_BENCH_CASES = (
    (; name = "simple", make_algo = resolve_bench_simple, runnable = true, inputs = ()),
    (; name = "routed", make_algo = resolve_bench_routed, runnable = true, inputs = ()),
    (; name = "shared", make_algo = resolve_bench_shared, runnable = true, inputs = (Input(ResolveBenchVectorPush, :source => 1.0),)),
    (; name = "nested", make_algo = resolve_bench_nested, runnable = true, inputs = ()),
)

function seconds(f)
    start = time_ns()
    result = f()
    return (time_ns() - start) / 1e9, result
end

function timed_stage!(f, rows, name)
    elapsed, result = seconds(f)
    push!(rows, name => elapsed)
    return result
end

function run_once!(process)
    reset!(process)
    run(process)
    wait(process)
    close(process)
    return process
end

function run_hot_resolves!(make_algo, n)
    resolved = nothing
    for _ in 1:n
        resolved = resolve(make_algo())
    end
    return resolved
end

function one_trial(case)
    rows = Pair{String,Float64}[]

    algo = timed_stage!(rows, "algo construction") do
        case.make_algo()
    end

    resolved = timed_stage!(rows, "resolve") do
        resolve(algo)
    end

    timed_stage!(rows, "resolve resolved") do
        resolve(resolved)
    end

    timed_stage!(rows, "initcontext") do
        initcontext(resolved)
    end

    if case.runnable
        process = timed_stage!(rows, "Process constructor") do
            Process(case.make_algo(), case.inputs...; repeats = 1)
        end

        timed_stage!(rows, "first run") do
            run_once!(process)
        end
    end

    timed_stage!(rows, "hot fresh resolves") do
        run_hot_resolves!(case.make_algo, PRB_HOT_RESOLVES)
    end

    return (; rows)
end

function print_trial(idx, trial)
    println("  Trial ", idx)
    for (name, elapsed) in trial.rows
        unit = name == "hot fresh resolves" ? " ms total" : " ms"
        println("    ", rpad(name * ":", 24), round(elapsed * 1000; digits = 3), unit)
        if name == "hot fresh resolves"
            println("    ", rpad("hot resolve avg:", 24), round(elapsed * 1e6 / PRB_HOT_RESOLVES; digits = 3), " us")
        end
    end
    return nothing
end

function main()
    println("Process resolve benchmark")
    println("  threads:      ", Threads.nthreads())
    println("  trials:       ", PRB_TRIALS)
    println("  hot resolves: ", PRB_HOT_RESOLVES)
    println()

    results = map(RESOLVE_BENCH_CASES) do case
        println(case.name)
        trials = [one_trial(case) for _ in 1:PRB_TRIALS]
        for (idx, trial) in enumerate(trials)
            print_trial(idx, trial)
        end
        println()
        return case.name => trials
    end

    return results
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main()
