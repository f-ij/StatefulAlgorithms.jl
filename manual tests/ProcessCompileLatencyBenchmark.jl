include("_env.jl")

const PCL_TRIALS = parse(Int, get(ENV, "PROCESSES_COMPILE_TRIALS", "3"))
const PCL_HOT_RUNS = parse(Int, get(ENV, "PROCESSES_COMPILE_HOT_RUNS", "2000"))

@ProcessAlgorithm function CompileBenchStep(
    x,
    @managed(total = start);
    gain = 1.0,
    @inputs((; start = 0.0))
)
    total = total + x * gain
    return (; total)
end

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

function run_hot!(process, n)
    for _ in 1:n
        run_once!(process)
    end
    return process
end

function one_trial()
    rows = Pair{String,Float64}[]

    algo = timed_stage!(rows, "algo construction") do
        CompositeAlgorithm(CompileBenchStep)
    end

    resolved_algo = timed_stage!(rows, "algo resolve") do
        resolve(algo)
    end

    inputs_overrides = (
        Input(CompileBenchStep, :start => 1.0),
        Override(CompileBenchStep, :x => 2.0, :gain => 3.0),
    )

    named_inputs, named_overrides = timed_stage!(rows, "input resolution") do
        StatefulAlgorithms.resolve_process_inputs_overrides(resolved_algo, inputs_overrides...)
    end

    initialized_algo = timed_stage!(rows, "lifecycle init") do
        StatefulAlgorithms.init(algo, inputs_overrides...; lifetime = Repeat(1))
    end

    context = timed_stage!(rows, "stored context") do
        StatefulAlgorithms.getstoredcontext(initialized_algo)
    end

    process = timed_stage!(rows, "Process constructor") do
        Process(algo, inputs_overrides...; repeats = 1)
    end

    timed_stage!(rows, "first run") do
        run_once!(process)
    end

    initialized_process = timed_stage!(rows, "Process from initialized") do
        Process(initialized_algo; repeats = 1)
    end

    timed_stage!(rows, "initialized first run") do
        run_once!(initialized_process)
    end

    timed_stage!(rows, "hot runs") do
        run_hot!(process, PCL_HOT_RUNS)
    end

    return (; rows, context)
end

function print_trial(idx, trial)
    println("Trial ", idx)
    for (name, elapsed) in trial.rows
        unit = name == "hot runs" ? " ms total" : " ms"
        println("  ", rpad(name * ":", 22), round(elapsed * 1000; digits = 3), unit)
        if name == "hot runs"
            println("  ", rpad("hot run avg:", 22), round(elapsed * 1e6 / PCL_HOT_RUNS; digits = 3), " us")
        end
    end
    return nothing
end

function main()
    println("Process compile latency benchmark")
    println("  threads:  ", Threads.nthreads())
    println("  trials:   ", PCL_TRIALS)
    println("  hot runs: ", PCL_HOT_RUNS)
    println()

    trials = [one_trial() for _ in 1:PCL_TRIALS]
    for (idx, trial) in enumerate(trials)
        print_trial(idx, trial)
    end
    return trials
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main()
