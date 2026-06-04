include("_env.jl")

const PHB_PROCESS_EPOCHS = parse(Int, get(ENV, "PROCESSES_HOT_PROCESS_EPOCHS", "2000"))
const PHB_INLINE_EPOCHS = parse(Int, get(ENV, "PROCESSES_HOT_INLINE_EPOCHS", "20000"))
const PHB_TRIALS = parse(Int, get(ENV, "PROCESSES_HOT_TRIALS", "5"))

@ProcessAlgorithm function NormalHotStep(
    @managed(
        total = Ref(0.0),
        x = Ref(1.0),
    );
    @inputs((;))
)
    total[] += x[]
    return (;)
end

function seconds(f)
    start = time_ns()
    result = f()
    return (time_ns() - start) / 1e9, result
end

function run_process_once!(process)
    reset!(process)
    run(process)
    wait(process)
    close(process)
    return process
end

function run_process_epochs!(process, epochs)
    for _ in 1:epochs
        run_process_once!(process)
    end
    return process
end

function run_inline_epochs!(process, epochs)
    for _ in 1:epochs
        reset!(process)
        run(process)
    end
    return process
end

function measure_hot(make_process, run_epochs!, epochs; trials = PHB_TRIALS)
    construct_time, process = seconds(make_process)
    warmup_time, _ = seconds(() -> run_epochs!(process, 1))

    times = Float64[]
    for _ in 1:trials
        elapsed, _ = seconds(() -> run_epochs!(process, epochs))
        push!(times, elapsed)
    end

    return (;
        construct_time,
        warmup_time,
        epochs,
        trials,
        times,
        min_time = minimum(times),
        mean_time = sum(times) / length(times),
        min_epoch = minimum(times) / epochs,
        mean_epoch = (sum(times) / length(times)) / epochs,
    )
end

function print_result(label, result)
    println(label)
    println("  construct:      ", round(result.construct_time * 1000; digits = 3), " ms")
    println("  warmup:         ", round(result.warmup_time * 1000; digits = 3), " ms")
    println("  hot epochs:     ", result.epochs)
    println("  hot trials:     ", result.trials)
    println("  hot times:      ", round.(result.times .* 1000; digits = 3), " ms")
    println("  hot min total:  ", round(result.min_time * 1000; digits = 3), " ms")
    println("  hot mean total: ", round(result.mean_time * 1000; digits = 3), " ms")
    println("  hot min epoch:  ", round(result.min_epoch * 1e6; digits = 3), " us")
    println("  hot mean epoch: ", round(result.mean_epoch * 1e6; digits = 3), " us")
    return nothing
end

function main()
    println("Process hot-loop benchmark")
    println("  threads:        ", Threads.nthreads())
    println("  process epochs: ", PHB_PROCESS_EPOCHS)
    println("  inline epochs:  ", PHB_INLINE_EPOCHS)
    println("  trials:         ", PHB_TRIALS)
    println()

    process_result = measure_hot(
        () -> Process(NormalHotStep; repeats = 1),
        run_process_epochs!,
        PHB_PROCESS_EPOCHS,
    )
    inline_result = measure_hot(
        () -> InlineProcess(NormalHotStep; repeats = 1),
        run_inline_epochs!,
        PHB_INLINE_EPOCHS,
    )

    print_result("Process reset/run/wait/close", process_result)
    print_result("InlineProcess reset/run", inline_result)
    return (; process_result, inline_result)
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main()
