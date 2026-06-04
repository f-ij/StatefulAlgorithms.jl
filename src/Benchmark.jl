function benchmark(func::Union{ProcessAlgorithm, AbstractLoopAlgorithm}, rt, trials = 100; loopfunction = nothing, progress = false, print_outer = false)
    p = Process(func; repeats = rt)
    runtimes = []
    outer_times = []
    for t_idx in 1:trials
        if progress
            println("Trial $t_idx")
        end
        makecontext!(p)
        ti = time_ns()
        run(p)
        fetch(p)
        push!(runtimes, runtime(p))
        push!(outer_times, (time_ns() - ti) / 1e9)
    end
    if print_outer
        println("Outer times over $trials trials: ", sum(outer_times)/trials)
    end
    return sum(runtimes) / trials
end
export benchmark
