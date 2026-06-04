using LinearAlgebra
using Printf
using StatefulAlgorithms
using Statistics

BLAS.set_num_threads(1)

struct ActualWorkJob{Id, Amount, Size}
    id::Id
    amount::Amount
    size::Size
end

"""
    ActualWorkJob(id, amount, size)

Create one real-process benchmark job with validated non-negative work sizes.
"""
function ActualWorkJob(id::I, amount::A, size::S) where {I<:Integer, A<:Integer, S<:Integer}
    amount >= 0 || throw(ArgumentError("`amount` must be non-negative."))
    size >= 0 || throw(ArgumentError("`size` must be non-negative."))
    return ActualWorkJob{I, A, S}(id, amount, size)
end

struct ActualLinearAlgebraWork <: StatefulAlgorithms.ProcessAlgorithm end
struct ActualTrajectoryWork <: StatefulAlgorithms.ProcessAlgorithm end
struct ActualSortWork <: StatefulAlgorithms.ProcessAlgorithm end

struct ActualProcessWorkload{Name, Template, Jobs, Prepare, Checksum}
    name::Name
    template::Template
    jobs::Jobs
    prepare!::Prepare
    checksum::Checksum
end

"""
    ActualProcessWorkload(name, template, jobs, prepare!, checksum)

Group one real `Process` workload with its preparation and checksum callbacks.
"""
function ActualProcessWorkload(
    name::N,
    template::T,
    jobs::J,
    prepare_callback::P,
    checksum_callback::C,
) where {N<:AbstractString, T<:Process, J<:AbstractVector, P, C}
    return ActualProcessWorkload{N, T, J, P, C}(name, template, jobs, prepare_callback, checksum_callback)
end

"""
    StatefulAlgorithms.init(::ActualLinearAlgebraWork, context)

Initialize a deterministic matrix-vector workload with reusable buffers.
"""
function StatefulAlgorithms.init(::ActualLinearAlgebraWork, context::C) where {C}
    dim = get(context, :dim, 256)
    matrix = Matrix{Float64}(undef, dim, dim)
    state = Vector{Float64}(undef, dim)
    scratch = similar(state)

    @inbounds for j in 1:dim, i in 1:dim
        matrix[i, j] = (sin(0.013 * i * j) + cos(0.017 * (i + j))) / sqrt(dim)
    end
    @inbounds for i in eachindex(state)
        state[i] = sin(0.11 * i)
        scratch[i] = 0.0
    end

    return (; passes = Ref(1), matrix, state, scratch, checksum = Ref(0.0))
end

"""
    StatefulAlgorithms.step!(::ActualLinearAlgebraWork, context)

Run repeated matrix-vector transforms with in-place state updates.
"""
function StatefulAlgorithms.step!(::ActualLinearAlgebraWork, context::C) where {C}
    @inbounds for _ in 1:context.passes[]
        mul!(context.scratch, context.matrix, context.state)
        for i in eachindex(context.state, context.scratch)
            value = context.scratch[i]
            context.state[i] = 0.82 * context.state[i] + 0.18 * tanh(value)
        end
    end
    context.checksum[] = sum(context.state)
    return (;)
end

"""
    StatefulAlgorithms.init(::ActualTrajectoryWork, context)

Initialize reusable particle state for a nonlinear trajectory workload.
"""
function StatefulAlgorithms.init(::ActualTrajectoryWork, context::C) where {C}
    n = get(context, :n, 2_048)
    position = Vector{Float64}(undef, n)
    velocity = Vector{Float64}(undef, n)

    @inbounds for i in 1:n
        position[i] = sin(0.01 * i)
        velocity[i] = cos(0.013 * i)
    end

    return (; steps = Ref(1), dt = Ref(0.002), position, velocity, checksum = Ref(0.0))
end

"""
    StatefulAlgorithms.step!(::ActualTrajectoryWork, context)

Integrate a deterministic nonlinear particle system for the requested number of
steps.
"""
function StatefulAlgorithms.step!(::ActualTrajectoryWork, context::C) where {C}
    dt = context.dt[]
    @inbounds for _ in 1:context.steps[]
        for i in eachindex(context.position, context.velocity)
            x = context.position[i]
            v = context.velocity[i]
            force = sin(x) - 0.05 * v + 0.01 * cos(0.25 * x)
            next_v = v + dt * force
            context.position[i] = x + dt * next_v
            context.velocity[i] = next_v
        end
    end
    context.checksum[] = sum(context.position) + 0.5 * sum(context.velocity)
    return (;)
end

"""
    StatefulAlgorithms.init(::ActualSortWork, context)

Initialize scalar controls for an allocation-heavy sorting workload.
"""
function StatefulAlgorithms.init(::ActualSortWork, context::C) where {C}
    return (; n = Ref(get(context, :n, 16_384)), seed = Ref(UInt64(1)), checksum = Ref(0.0))
end

"""
    StatefulAlgorithms.step!(::ActualSortWork, context)

Allocate, fill, and sort a deterministic vector for one job.
"""
function StatefulAlgorithms.step!(::ActualSortWork, context::C) where {C}
    n = context.n[]
    data = Vector{Float64}(undef, n)
    state = context.seed[]

    @inbounds for i in 1:n
        state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        data[i] = Float64(state % UInt64(10_000_000)) / 10_000_000
    end

    sort!(data)
    context.seed[] = state
    context.checksum[] = data[1] + data[max(1, div(n, 2))] + data[end]
    return (;)
end

"""
    actual_process_context(worker)

Return the single algorithm subcontext from a benchmark `Process` worker.
"""
function actual_process_context(worker::P) where {P<:Process}
    subcontexts = StatefulAlgorithms.get_subcontexts(StatefulAlgorithms.context(worker))
    names = filter(!=(:globals), fieldnames(typeof(subcontexts)))
    return getproperty(subcontexts, only(names))
end

"""
    parse_actual_process_args(args)

Read `key=value` command-line options for the real-process benchmark runner.
"""
function parse_actual_process_args(args::A) where {A<:AbstractVector}
    options = Dict{String, String}()
    for arg in args
        key, value = split(arg, "="; limit = 2)
        options[key] = value
    end

    return (;
        scale = parse(Float64, get(options, "scale", "1.0")),
        samples = parse(Int, get(options, "samples", "3")),
        warmup = parse(Int, get(options, "warmup", "1")),
    )
end

"""
    scaled_count(value, scale; minimum = 1)

Scale job counts for quick local runs without changing workload character.
"""
function scaled_count(value::T, scale::S; minimum::M = 1) where {T<:Integer, S<:Real, M<:Integer}
    return max(minimum, round(Int, value * scale))
end

"""
    make_actual_process_workloads(scale)

Build real managed-process workloads with balanced and long-tailed job costs.
"""
function make_actual_process_workloads(scale::S) where {S<:Real}
    linalg_n = scaled_count(384, scale; minimum = 64)
    trajectory_n = scaled_count(256, scale; minimum = 64)
    sort_n = scaled_count(192, scale; minimum = 48)

    linalg_template = Process(ActualLinearAlgebraWork(); repeats = 1)
    trajectory_template = Process(ActualTrajectoryWork(); repeats = 1)
    sort_template = Process(ActualSortWork(); repeats = 1)

    linalg_prepare = (slot, job, manager) -> begin
        ctx = actual_process_context(slot.worker)
        ctx.passes[] = job.amount
        @inbounds for i in eachindex(ctx.state)
            ctx.state[i] = sin(0.001 * job.id + 0.011 * i)
        end
        resetworker!(slot)
        nothing
    end
    trajectory_prepare = (slot, job, manager) -> begin
        ctx = actual_process_context(slot.worker)
        ctx.steps[] = job.amount
        @inbounds for i in eachindex(ctx.position, ctx.velocity)
            ctx.position[i] = sin(0.002 * job.id + 0.01 * i)
            ctx.velocity[i] = cos(0.003 * job.id + 0.013 * i)
        end
        resetworker!(slot)
        nothing
    end
    sort_prepare = (slot, job, manager) -> begin
        ctx = actual_process_context(slot.worker)
        ctx.n[] = job.size
        ctx.seed[] = UInt64(job.id + 1)
        resetworker!(slot)
        nothing
    end
    checksum_callback = ctx -> ctx.checksum[]

    linalg_tail_start = floor(Int, linalg_n * 0.85)
    trajectory_tail_start = floor(Int, trajectory_n * 0.85)
    sort_tail_start = floor(Int, sort_n * 0.80)

    return (
        ActualProcessWorkload(
            "process_linalg_equal",
            linalg_template,
            [ActualWorkJob(i, 20, 0) for i in 1:linalg_n],
            linalg_prepare,
            checksum_callback,
        ),
        ActualProcessWorkload(
            "process_linalg_tail",
            linalg_template,
            [ActualWorkJob(i, i > linalg_tail_start ? 120 : 12, 0) for i in 1:linalg_n],
            linalg_prepare,
            checksum_callback,
        ),
        ActualProcessWorkload(
            "process_trajectory_equal",
            trajectory_template,
            [ActualWorkJob(i, 180, 0) for i in 1:trajectory_n],
            trajectory_prepare,
            checksum_callback,
        ),
        ActualProcessWorkload(
            "process_trajectory_tail",
            trajectory_template,
            [ActualWorkJob(i, i > trajectory_tail_start ? 1_000 : 90, 0) for i in 1:trajectory_n],
            trajectory_prepare,
            checksum_callback,
        ),
        ActualProcessWorkload(
            "process_sort_tail",
            sort_template,
            [ActualWorkJob(i, 0, i > sort_tail_start ? 131_072 : 16_384) for i in 1:sort_n],
            sort_prepare,
            checksum_callback,
        ),
    )
end

"""
    actual_process_manager(workload, nworkers)

Create a typed manager with reusable copies of a workload template process.
"""
function actual_process_manager(workload::W, nworkers::N) where {W<:ActualProcessWorkload, N<:Integer}
    recipe = (;
        makeworker = (idx, manager) -> copyprocess(workload.template; context = deepcopy(StatefulAlgorithms.context(workload.template))),
        prepare! = workload.prepare!,
    )

    return ProcessManager(
        recipe;
        nworkers,
        flush_policy = NoFlush(),
        job_type = eltype(workload.jobs),
        result_type = Any,
        error_type = Any,
    )
end

"""
    actual_process_checksum(manager, workload)

Combine slot-local process checksums after one benchmark run.
"""
function actual_process_checksum(manager::M, workload::W) where {M<:ProcessManager, W<:ActualProcessWorkload}
    total = 0.0
    for slot in slots(manager)
        total += workload.checksum(actual_process_context(slot.worker))
    end
    return total
end

"""
    run_actual_process_schedule(workload, mode_name, schedule, nworkers, warmup, samples)

Benchmark one real-process workload under one threaded manager schedule.
"""
function run_actual_process_schedule(
    workload::W,
    mode_name::MN,
    schedule::S,
    nworkers::N,
    warmup::WU,
    samples::SP,
) where {W<:ActualProcessWorkload, MN<:AbstractString, S<:ThreadsType, N<:Integer, WU<:Integer, SP<:Integer}
    for _ in 1:warmup
        warm_manager = actual_process_manager(workload, nworkers)
        runthreaded!(warm_manager, workload.jobs, schedule)
    end

    times = Float64[]
    bytes = Int[]
    checksum = 0.0
    for _ in 1:samples
        manager = actual_process_manager(workload, nworkers)
        GC.gc()
        timed = @timed runthreaded!(manager, workload.jobs, schedule)
        push!(times, timed.time)
        push!(bytes, timed.bytes)
        checksum = actual_process_checksum(manager, workload)
    end

    return (;
        workload = workload.name,
        mode = mode_name,
        seconds = median(times),
        bytes = round(Int, median(bytes)),
        checksum,
    )
end

"""
    print_actual_process_results(results)

Print all real-process benchmark timings and the fastest schedule per workload.
"""
function print_actual_process_results(results::R) where {R<:AbstractVector}
    println()
    println("workload                    mode       median seconds   median bytes")
    println("--------------------------------------------------------------------")
    for result in results
        @printf("%-27s %-10s %14.6f %14d\n", result.workload, result.mode, result.seconds, result.bytes)
    end

    println()
    println("fastest mode per workload")
    println("-------------------------")
    for workload in unique(result.workload for result in results)
        group = filter(result -> result.workload == workload, results)
        fastest = group[argmin(result.seconds for result in group)]
        @printf("%-27s %-10s %.6f s\n", workload, fastest.mode, fastest.seconds)
    end
    return results
end

"""
    main(args)

Run real managed-process workloads through `Dynamic`, `Static`, and `Greedy`.
"""
function main(args::A = ARGS) where {A<:AbstractVector}
    options = parse_actual_process_args(args)
    options.samples > 0 || throw(ArgumentError("`samples` must be positive."))
    options.warmup >= 0 || throw(ArgumentError("`warmup` must be non-negative."))

    nworkers = Threads.maxthreadid()
    workloads = make_actual_process_workloads(options.scale)
    schedules = (
        ("dynamic", Dynamic()),
        ("static", Static()),
        ("greedy", Greedy()),
    )

    println("ProcessManager actual process workload comparison")
    println("threads:      ", Threads.nthreads())
    println("max tid:      ", Threads.maxthreadid())
    println("workers:      ", nworkers)
    println("BLAS threads: ", BLAS.get_num_threads())
    println("scale:        ", options.scale)
    println("samples:      ", options.samples)

    results = NamedTuple[]
    for workload in workloads
        println()
        println("running $(workload.name) with $(length(workload.jobs)) jobs")
        for (mode_name, schedule) in schedules
            result = run_actual_process_schedule(workload, mode_name, schedule, nworkers, options.warmup, options.samples)
            push!(results, result)
            @printf("  %-8s %.6f s, %d bytes\n", mode_name, result.seconds, result.bytes)
        end
    end

    print_actual_process_results(results)
    return results
end

main()
