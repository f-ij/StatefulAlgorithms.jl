using Printf
using Profile
using StatefulAlgorithms
using Statistics

struct ThreadedModeJob{Id, Work, Alloc, Sleep}
    id::Id
    work::Work
    alloc_len::Alloc
    sleep_seconds::Sleep
end

"""
    ThreadedModeJob(id, work, alloc_len, sleep_seconds)

Create one benchmark job with concrete field types and validated non-negative
workload sizes.
"""
function ThreadedModeJob(id::I, work::W, alloc_len::A, sleep_seconds::S) where {I<:Integer, W<:Integer, A<:Integer, S<:Real}
    work >= 0 || throw(ArgumentError("`work` must be non-negative."))
    alloc_len >= 0 || throw(ArgumentError("`alloc_len` must be non-negative."))
    sleep_seconds >= 0 || throw(ArgumentError("`sleep_seconds` must be non-negative."))
    return ThreadedModeJob{I, W, A, S}(id, work, alloc_len, sleep_seconds)
end

mutable struct ThreadedModeWorker{Total, Buffer}
    total::Total
    buffer::Buffer
end

"""
    ThreadedModeWorker()

Create a slot-local fake worker used to isolate manager schedule behavior.
"""
ThreadedModeWorker() = ThreadedModeWorker{UInt64, Vector{UInt64}}(UInt64(0), UInt64[])

struct ThreadedModeWorkload{Name, Jobs}
    name::Name
    jobs::Jobs
end

"""
    ThreadedModeWorkload(name, jobs)

Group a named job vector so reports can compare schedules per workload.
"""
function ThreadedModeWorkload(name::N, jobs::J) where {N<:AbstractString, J<:AbstractVector}
    return ThreadedModeWorkload{N, J}(name, jobs)
end

struct ThreadedModeResult{Workload, Mode, Seconds, Bytes, Spread, Checksum}
    workload::Workload
    mode::Mode
    seconds::Seconds
    bytes::Bytes
    spread::Spread
    checksum::Checksum
end

"""
    parse_threaded_mode_args(args)

Read simple `key=value` command-line options and boolean flags for the profiling
runner.
"""
function parse_threaded_mode_args(args::A) where {A<:AbstractVector}
    options = Dict{String, String}()
    flags = Set{String}()
    for arg in args
        if occursin("=", arg)
            key, value = split(arg, "="; limit = 2)
            options[key] = value
        else
            push!(flags, arg)
        end
    end

    return (;
        scale = parse(Float64, get(options, "scale", "1.0")),
        samples = parse(Int, get(options, "samples", "5")),
        warmup = parse(Int, get(options, "warmup", "1")),
        profile_repeats = parse(Int, get(options, "profile_repeats", "6")),
        profile = "profile" in flags,
    )
end

"""
    scaled_count(value, scale; minimum = 1)

Scale a benchmark size while keeping small test runs meaningful.
"""
function scaled_count(value::T, scale::S; minimum::M = 1) where {T<:Integer, S<:Real, M<:Integer}
    return max(minimum, round(Int, value * scale))
end

"""
    make_threaded_mode_workloads(scale)

Build balanced, skewed, allocating, and yielding workloads for schedule
comparison.
"""
function make_threaded_mode_workloads(scale::S) where {S<:Real}
    tiny_n = scaled_count(40_000, scale; minimum = 1_000)
    cpu_n = scaled_count(8_000, scale; minimum = 256)
    alloc_n = scaled_count(5_000, scale; minimum = 256)
    sleep_n = scaled_count(1_000, scale; minimum = 64)

    # Keep all jobs in one concrete element type so manager slot fields can be
    # specialized on `job_type = eltype(jobs)`.
    tiny_equal = [ThreadedModeJob(i, 24, 0, 0.0) for i in 1:tiny_n]
    cpu_equal = [ThreadedModeJob(i, 2_400, 0, 0.0) for i in 1:cpu_n]
    cpu_tail_start = floor(Int, cpu_n * 0.85)
    cpu_skewed = [
        ThreadedModeJob(i, i > cpu_tail_start ? 60_000 : 700, 0, 0.0)
        for i in 1:cpu_n
    ]
    allocation_mixed = [
        ThreadedModeJob(i, 180, i % 11 == 0 ? 4_096 : 64, 0.0)
        for i in 1:alloc_n
    ]
    sleep_tail_start = floor(Int, sleep_n * 0.85)
    sleep_skewed = [
        ThreadedModeJob(i, 80, 0, i > sleep_tail_start ? 0.003 : 0.0)
        for i in 1:sleep_n
    ]

    return (
        ThreadedModeWorkload("tiny_equal", tiny_equal),
        ThreadedModeWorkload("cpu_equal", cpu_equal),
        ThreadedModeWorkload("cpu_skewed", cpu_skewed),
        ThreadedModeWorkload("allocation_mixed", allocation_mixed),
        ThreadedModeWorkload("sleep_skewed", sleep_skewed),
    )
end

"""
    run_threaded_mode_work!(worker, job)

Execute one synthetic job inside the borrowed manager slot.
"""
function run_threaded_mode_work!(worker::W, job::J) where {W<:ThreadedModeWorker, J<:ThreadedModeJob}
    acc = xor(worker.total, UInt64(job.id))

    # Integer mixing gives deterministic CPU work that the compiler cannot
    # collapse to a constant across jobs.
    @inbounds for i in 1:job.work
        acc = xor(acc, UInt64(i + job.id)) * UInt64(0x9e3779b97f4a7c15)
        acc = (acc << 7) | (acc >> 57)
    end

    if job.alloc_len > 0
        buffer = Vector{UInt64}(undef, job.alloc_len)
        @inbounds for i in eachindex(buffer)
            value = acc + UInt64(i)
            buffer[i] = value
            acc = xor(acc, value)
        end
        worker.buffer = buffer
    end

    if job.sleep_seconds > 0
        sleep(job.sleep_seconds)
    end

    worker.total = acc
    return acc
end

"""
    threaded_mode_recipe()

Create a recipe whose `start!` callback performs all synthetic work
synchronously inside the current threaded manager iteration.
"""
function threaded_mode_recipe()
    return (;
        makeworker = (idx, manager) -> ThreadedModeWorker(),
        start! = (slot, job, manager) -> begin
            slot.result = run_threaded_mode_work!(slot.worker, job)
            nothing
        end,
        isdone = (slot, manager) -> true,
        finalize! = (slot, job, manager) -> slot.result,
    )
end

"""
    threaded_mode_manager(nworkers, jobs)

Create a typed manager for one workload run.
"""
function threaded_mode_manager(nworkers::T, jobs::J) where {T<:Integer, J<:AbstractVector}
    return ProcessManager(
        threaded_mode_recipe();
        nworkers,
        flush_policy = NoFlush(),
        job_type = eltype(jobs),
        result_type = UInt64,
        error_type = Any,
    )
end

"""
    schedule_spread(manager)

Return the difference between the busiest and least busy slot that ran work
after a run.
"""
function schedule_spread(manager::M) where {M<:ProcessManager}
    counts = filter(>(0), map(slot -> slot.runs, slots(manager)))
    isempty(counts) && return 0
    return maximum(counts) - minimum(counts)
end

"""
    manager_checksum(manager)

Combine worker-local totals so benchmark results remain observable.
"""
function manager_checksum(manager::M) where {M<:ProcessManager}
    checksum = UInt64(0)
    for slot in slots(manager)
        checksum = xor(checksum, slot.worker.total)
    end
    return checksum
end

"""
    run_one_schedule(workload, mode_name, schedule, nworkers, warmup, samples)

Benchmark one workload and schedule, returning the median elapsed time and
median allocation count across samples.
"""
function run_one_schedule(
    workload::WL,
    mode_name::MN,
    schedule::S,
    nworkers::N,
    warmup::W,
    samples::SP,
) where {WL<:ThreadedModeWorkload, MN<:AbstractString, S<:ThreadsType, N<:Integer, W<:Integer, SP<:Integer}
    jobs = workload.jobs
    for _ in 1:warmup
        warm_manager = threaded_mode_manager(nworkers, jobs)
        runthreaded!(warm_manager, jobs, schedule)
    end

    times = Float64[]
    bytes = Int[]
    spread = 0
    checksum = UInt64(0)
    for _ in 1:samples
        manager = threaded_mode_manager(nworkers, jobs)
        GC.gc()
        timed = @timed runthreaded!(manager, jobs, schedule)
        push!(times, timed.time)
        push!(bytes, timed.bytes)
        spread = schedule_spread(manager)
        checksum = manager_checksum(manager)
    end

    return ThreadedModeResult(
        workload.name,
        mode_name,
        median(times),
        round(Int, median(bytes)),
        spread,
        checksum,
    )
end

"""
    print_threaded_mode_table(results)

Print a compact comparison table and fastest schedule per workload.
"""
function print_threaded_mode_table(results::R) where {R<:AbstractVector}
    println()
    println("workload             mode       median seconds   median bytes   used spread")
    println("--------------------------------------------------------------------------")
    for result in results
        @printf(
            "%-20s %-10s %14.6f %14d %13d\n",
            result.workload,
            result.mode,
            result.seconds,
            result.bytes,
            result.spread,
        )
    end

    println()
    println("fastest mode per workload")
    println("-------------------------")
    for workload in unique(result.workload for result in results)
        group = filter(result -> result.workload == workload, results)
        fastest = group[argmin(result.seconds for result in group)]
        @printf("%-20s %-10s %.6f s\n", workload, fastest.mode, fastest.seconds)
    end
    return results
end

"""
    profile_one_schedule(workload, mode_name, schedule, nworkers, repeats)

Print sampled profile data for one workload and schedule.
"""
function profile_one_schedule(
    workload::WL,
    mode_name::MN,
    schedule::S,
    nworkers::N,
    repeats::R,
) where {WL<:ThreadedModeWorkload, MN<:AbstractString, S<:ThreadsType, N<:Integer, R<:Integer}
    manager = threaded_mode_manager(nworkers, workload.jobs)
    runthreaded!(manager, workload.jobs, schedule)

    Profile.clear()
    @profile for _ in 1:repeats
        manager = threaded_mode_manager(nworkers, workload.jobs)
        runthreaded!(manager, workload.jobs, schedule)
    end

    println()
    println("== $(workload.name) / $mode_name profile ==")
    Profile.print(format = :flat, sortedby = :count, maxdepth = 32, mincount = 2)
    return nothing
end

"""
    main(args)

Run the threaded mode benchmark suite and optionally sampled profiles.
"""
function main(args::A = ARGS) where {A<:AbstractVector}
    options = parse_threaded_mode_args(args)
    options.samples > 0 || throw(ArgumentError("`samples` must be positive."))
    options.warmup >= 0 || throw(ArgumentError("`warmup` must be non-negative."))

    nworkers = Threads.maxthreadid()
    workloads = make_threaded_mode_workloads(options.scale)
    schedules = (
        ("dynamic", Dynamic()),
        ("static", Static()),
        ("greedy", Greedy()),
    )

    println("ProcessManager threaded schedule comparison")
    println("threads:  ", Threads.nthreads())
    println("max tid:  ", Threads.maxthreadid())
    println("workers:  ", nworkers)
    println("scale:    ", options.scale)
    println("samples:  ", options.samples)

    results = ThreadedModeResult[]
    for workload in workloads
        println()
        println("running $(workload.name) with $(length(workload.jobs)) jobs")
        for (mode_name, schedule) in schedules
            result = run_one_schedule(
                workload,
                mode_name,
                schedule,
                nworkers,
                options.warmup,
                options.samples,
            )
            push!(results, result)
            @printf(
                "  %-8s %.6f s, %d bytes, spread %d\n",
                mode_name,
                result.seconds,
                result.bytes,
                result.spread,
            )
        end
    end

    print_threaded_mode_table(results)

    if options.profile
        for workload in workloads
            for (mode_name, schedule) in schedules
                profile_one_schedule(workload, mode_name, schedule, nworkers, options.profile_repeats)
            end
        end
    end
    return results
end

main()
