include("_env.jl")
include("InterestingGraphBenchmark.jl")

using Profile
using Random

function build_process(algo, start_x, start_y; repeats)
    n = length(start_x)
    return Process(
        algo,
        Input(SourceXBench, :start_x => copy(start_x)),
        Input(SourceYBench, :start_y => copy(start_y)),
        Input(StageABench; n),
        Input(StageBBench; n),
        Input(StageCBench; n),
        Input(JoinDBench; n),
        Input(JoinEBench; n),
        Input(StageFBench; n),
        Input(StageGBench; n),
        Input(StageHBench; n);
        lifetime = repeats,
    )
end

function profiled_run(algo, start_x, start_y; repeats)
    p = build_process(algo, start_x, start_y; repeats)
    run(p)
    wait(p)
    ctx = fetch(p)
    quit(p)
    return ctx
end

function print_profile(label, algo, start_x, start_y; repeats, mincount = 5)
    profiled_run(algo, start_x, start_y; repeats = 1)
    GC.gc()
    Profile.clear()

    @profile profiled_run(algo, start_x, start_y; repeats)

    println()
    println("== ", label, " CPU profile ==")
    Profile.print(stdout; format = :flat, sortedby = :count, maxdepth = 14, mincount)
end

Random.seed!(1234)

n = 250_000
repeats = 4
start_x = randn(n)
start_y = randn(n)

_comp, threaded = build_algorithms()

print_profile("Threaded", threaded, start_x, start_y; repeats, mincount = 5)
