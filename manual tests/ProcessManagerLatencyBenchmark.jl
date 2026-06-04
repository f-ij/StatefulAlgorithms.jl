include("_env.jl")

const PMB_NWORKERS = parse(Int, get(ENV, "PROCESSES_MANAGER_BENCH_WORKERS", string(max(1, min(Threads.nthreads(), 4)))))
const PMB_EPOCHS = parse(Int, get(ENV, "PROCESSES_MANAGER_BENCH_EPOCHS", "40"))
const PMB_NSAMPLES = parse(Int, get(ENV, "PROCESSES_MANAGER_BENCH_SAMPLES", "128"))
const PMB_FIRST = get(ENV, "PROCESSES_MANAGER_BENCH_FIRST", "manager")

@ProcessAlgorithm function BenchLearningStep(
    @managed(
        x = Ref(0.0),
        y = Ref(0.0),
        params = Ref((w = 0.0, b = 0.0)),
        grad_w = Ref(0.0),
        grad_b = Ref(0.0),
        loss = Ref(0.0),
        nseen = Ref(0),
    );
    @inputs((;))
)
    current = params[]
    prediction = current.w * x[] + current.b
    err = prediction - y[]
    grad_w[] += err * x[]
    grad_b[] += err
    loss[] += 0.5 * err^2
    nseen[] += 1
    return (;)
end

function bench_context(worker)
    return worker.context[BenchLearningStep]
end

function reset_bench_buffers!(ctx)
    ctx.grad_w[] = 0.0
    ctx.grad_b[] = 0.0
    ctx.loss[] = 0.0
    ctx.nseen[] = 0
    return ctx
end

function make_dataset(n::Integer)
    return [(; x = sin(i / 7), y = 1.7 * sin(i / 7) - 0.2) for i in 1:n]
end

function make_bench_template()
    return Process(BenchLearningStep; repeats = 1)
end

function make_bench_state(; initial_params = (w = 0.0, b = 0.0), lr = 0.03)
    return (;
        params = Ref(initial_params),
        lr,
        epoch = Ref(0),
        total_loss = Ref(0.0),
    )
end

function flush_bench_workers!(state, workers)
    total_grad_w = 0.0
    total_grad_b = 0.0
    total_loss = 0.0
    total_seen = 0

    for worker in workers
        ctx = bench_context(worker)
        total_grad_w += ctx.grad_w[]
        total_grad_b += ctx.grad_b[]
        total_loss += ctx.loss[]
        total_seen += ctx.nseen[]
        reset_bench_buffers!(ctx)
    end

    total_seen == 0 && return state

    params = state.params[]
    scale = inv(total_seen)
    next_params = (;
        w = params.w - state.lr * total_grad_w * scale,
        b = params.b - state.lr * total_grad_b * scale,
    )
    state.params[] = next_params
    state.epoch[] += 1
    state.total_loss[] = total_loss

    for worker in workers
        bench_context(worker).params[] = next_params
    end

    return state
end

function make_manager_benchmark(dataset; nworkers = PMB_NWORKERS)
    template = make_bench_template()
    recipe = (;
        initstate = config -> make_bench_state(; initial_params = config.initial_params, lr = config.lr),
        makeworker = (idx, manager) -> copyprocess(template; context = deepcopy(template.context)),
        prepare! = (slot, sample, manager) -> begin
            ctx = bench_context(slot.worker)
            ctx.x[] = sample.x
            ctx.y[] = sample.y
            ctx.params[] = manager.state.params[]
            resetworker!(slot)
        end,
        flush! = manager -> flush_bench_workers!(manager.state, StatefulAlgorithms.workers(manager)),
    )

    return ProcessManager(
        recipe;
        nworkers,
        config = (; initial_params = (w = 0.0, b = 0.0), lr = 0.03),
        flush_policy = FlushAtEnd(),
        job_type = eltype(dataset),
        result_type = typeof(template),
    )
end

function run_manager_epoch!(manager, dataset)
    run!(manager, dataset)
    return manager.state
end

function make_handwritten_benchmark(; nworkers = PMB_NWORKERS)
    template = make_bench_template()
    workers = [
        idx == 1 ? template : copyprocess(template; context = deepcopy(template.context))
        for idx in 1:nworkers
    ]
    state = make_bench_state()
    return (; workers, state)
end

function start_handwritten_worker!(worker, sample, state)
    ctx = bench_context(worker)
    ctx.x[] = sample.x
    ctx.y[] = sample.y
    ctx.params[] = state.params[]
    reset!(worker)
    run(worker)
    return worker
end

function finish_handwritten_worker!(worker)
    wait(worker)
    close(worker)
    return worker
end

function run_handwritten_epoch!(bench, dataset)
    workers = bench.workers
    next_worker = 1
    active = Process[]

    for sample in dataset
        worker = workers[next_worker]
        start_handwritten_worker!(worker, sample, bench.state)
        push!(active, worker)

        if length(active) == length(workers)
            for active_worker in active
                finish_handwritten_worker!(active_worker)
            end
            empty!(active)
        end

        next_worker = next_worker == length(workers) ? 1 : next_worker + 1
    end

    for active_worker in active
        finish_handwritten_worker!(active_worker)
    end

    flush_bench_workers!(bench.state, workers)
    return bench.state
end

function timed_seconds(f)
    start = time_ns()
    result = f()
    elapsed = (time_ns() - start) / 1e9
    return elapsed, result
end

function measure_runner(make_runner, run_epoch!, dataset; epochs = PMB_EPOCHS)
    construct_time, runner = timed_seconds(make_runner)
    first_time, _ = timed_seconds(() -> run_epoch!(runner, dataset))

    epoch_times = Float64[]
    total_time, _ = timed_seconds() do
        for _ in 1:epochs
            elapsed, _ = timed_seconds(() -> run_epoch!(runner, dataset))
            push!(epoch_times, elapsed)
        end
    end

    avg_epoch = isempty(epoch_times) ? 0.0 : sum(epoch_times) / length(epoch_times)
    outer_time = construct_time + first_time + total_time
    return (; construct_time, first_time, total_time, avg_epoch, outer_time, final_state = runner.state)
end

function print_result(label, result)
    println(label)
    println("  construct latency: ", round(result.construct_time * 1000; digits = 3), " ms")
    println("  first epoch:       ", round(result.first_time * 1000; digits = 3), " ms")
    println("  total warmed run:  ", round(result.total_time * 1000; digits = 3), " ms")
    println("  avg warmed epoch:  ", round(result.avg_epoch * 1000; digits = 3), " ms")
    println("  outer runtime:     ", round(result.outer_time * 1000; digits = 3), " ms")
    println("  final params:      ", result.final_state.params[])
    println("  final loss:        ", result.final_state.total_loss[])
    return nothing
end

function main()
    dataset = make_dataset(PMB_NSAMPLES)
    println("ProcessManager latency benchmark")
    println("  threads:  ", Threads.nthreads())
    println("  workers:  ", PMB_NWORKERS)
    println("  samples:  ", PMB_NSAMPLES)
    println("  epochs:   ", PMB_EPOCHS)
    println("  first:    ", PMB_FIRST)
    println("  note:     the first runner pays Julia compilation for shared Process setup")
    println()

    if PMB_FIRST == "handwritten"
        handwritten_result = measure_runner(
            () -> make_handwritten_benchmark(; nworkers = PMB_NWORKERS),
            run_handwritten_epoch!,
            dataset,
        )
        manager_result = measure_runner(
            () -> make_manager_benchmark(dataset; nworkers = PMB_NWORKERS),
            run_manager_epoch!,
            dataset,
        )
    elseif PMB_FIRST == "manager"
        manager_result = measure_runner(
            () -> make_manager_benchmark(dataset; nworkers = PMB_NWORKERS),
            run_manager_epoch!,
            dataset,
        )
        handwritten_result = measure_runner(
            () -> make_handwritten_benchmark(; nworkers = PMB_NWORKERS),
            run_handwritten_epoch!,
            dataset,
        )
    else
        throw(ArgumentError("`PROCESSES_MANAGER_BENCH_FIRST` must be `manager` or `handwritten`."))
    end

    print_result("ProcessManager", manager_result)
    print_result("Handwritten loop", handwritten_result)

    println("Ratios")
    println("  construct:    ", round(manager_result.construct_time / handwritten_result.construct_time; digits = 3), "x")
    println("  first epoch:  ", round(manager_result.first_time / handwritten_result.first_time; digits = 3), "x")
    println("  warmed total: ", round(manager_result.total_time / handwritten_result.total_time; digits = 3), "x")
    println("  warmed epoch: ", round(manager_result.avg_epoch / handwritten_result.avg_epoch; digits = 3), "x")
    println("  outer:        ", round(manager_result.outer_time / handwritten_result.outer_time; digits = 3), "x")
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main()
