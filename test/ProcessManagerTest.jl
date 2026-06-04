using Test
using StatefulAlgorithms

mutable struct ManagerFakeWorker
    idx::Int
    buffer::Vector{Int}
    done::Bool
end

function immediate_fake_recipe(external, flush_count)
    return (;
        makeworker = (idx, manager) -> ManagerFakeWorker(idx, Int[], false),
        prepare! = (slot, job, manager) -> push!(slot.worker.buffer, job),
        start! = (slot, job, manager) -> (slot.worker.done = true),
        isdone = (slot, manager) -> slot.worker.done,
        finalize! = (slot, job, manager) -> (slot.worker.done = false),
        flush! = manager -> begin
            flush_count[] += 1
            for slot in slots(manager)
                append!(external, slot.worker.buffer)
                empty!(slot.worker.buffer)
            end
            return external
        end,
    )
end

@testset "ProcessManager stores flush policy traits" begin
    manager = ProcessManager(immediate_fake_recipe(Int[], Ref(0)); nworkers = 1)
    @test manager.flush_policy isa FlushAtEnd
    @test_throws ArgumentError ProcessManager(immediate_fake_recipe(Int[], Ref(0)); nworkers = 1, flush_policy = :end)
    @test_throws ArgumentError ProcessManager(immediate_fake_recipe(Int[], Ref(0)); nworkers = 1, worker_lifecycle = :reuse)
end

@testset "ProcessManager can keep slot fields concrete" begin
    manager = ProcessManager(
        immediate_fake_recipe(Int[], Ref(0));
        nworkers = 1,
        job_type = Int,
        result_type = Nothing,
    )

    @test manager.config === nothing
    @test eltype(slots(manager)) <: WorkerSlot{ManagerFakeWorker, Int, Any, Nothing, Any, Symbol}
    @test only(slots(manager)).name == :worker_1
end

@testset "ProcessManager show includes useful runtime state" begin
    manager = ProcessManager(immediate_fake_recipe(Int[], Ref(0)); nworkers = 2, job_type = Int)
    compact = sprint(show, manager)
    manager_summary = sprint(summary, manager)
    detailed = sprint(show, MIME("text/plain"), manager)
    slot_detail = sprint(show, MIME("text/plain"), first(slots(manager)))

    @test occursin("ProcessManager(open, workers=2", compact)
    @test manager_summary == "ProcessManager(2 workers, open)"
    @test occursin("active=0", compact)
    @test occursin("completions=0", compact)
    @test occursin("status = open", detailed)
    @test occursin("workers = 2 (active=0, idle=2)", detailed)
    @test occursin("progress = dispatched=0, completions=0", detailed)
    @test occursin("[1] :worker_1 idle runs=0", detailed)
    @test occursin("WorkerSlot", slot_detail)
    @test occursin("status = idle", slot_detail)
end

@testset "ProcessManager stores slots as a typed tuple" begin
    recipe = (;
        prepare! = (slot, job, manager) -> (slot.worker.done = true; push!(slot.worker.buffer, job)),
        isdone = (slot, manager) -> slot.worker.done,
    )
    manager = ProcessManager(
        recipe;
        workers = (ManagerFakeWorker(1, Int[], false), (; done = false, buffer = Int[])),
        job_type = Int,
    )

    @test slots(manager) isa Tuple
    @test workers(manager) isa Tuple
    @test typeof(slots(manager)) <: Tuple{
        WorkerSlot{ManagerFakeWorker, Int, Any, Any, Any, Symbol},
        WorkerSlot{@NamedTuple{done::Bool, buffer::Vector{Int}}, Int, Any, Any, Any, Symbol},
    }
end

@testset "ProcessManager copies one owned worker template" begin
    make_count = Ref(0)
    copy_count = Ref(0)
    recipe = (;
        makeworker = (idx, manager) -> begin
            make_count[] += 1
            ManagerFakeWorker(idx, Int[], false)
        end,
        copyworker = (template, idx, manager) -> begin
            copy_count[] += 1
            ManagerFakeWorker(idx, Int[], false)
        end,
    )

    manager = ProcessManager(recipe; nworkers = 4)

    @test make_count[] == 1
    @test copy_count[] == 3
    @test [slot.worker.idx for slot in slots(manager)] == 1:4
end

@testset "ProcessManager can make every owned worker independently" begin
    make_count = Ref(0)
    copy_count = Ref(0)
    worker_data = [10, 20, 30, 40]
    recipe = (;
        makeworker = (idx, manager, initdata) -> begin
            make_count[] += 1
            ManagerFakeWorker(idx, Int[initdata], false)
        end,
        copyworker = (template, idx, manager) -> begin
            copy_count[] += 1
            ManagerFakeWorker(idx, Int[], false)
        end,
    )

    manager = ProcessManager(
        recipe;
        nworkers = 4,
        worker_init = MakeEachWorker(),
        worker_init_data = worker_data,
    )

    @test make_count[] == 4
    @test copy_count[] == 0
    @test [slot.worker.idx for slot in slots(manager)] == 1:4
    @test [only(slot.worker.buffer) for slot in slots(manager)] == worker_data
    @test_throws ArgumentError ProcessManager(recipe; nworkers = 4, worker_init = MakeEachWorker(), worker_init_data = worker_data[1:3])
end

@testset "ProcessManager initializes owned state from config" begin
    recipe = (;
        initstate = config -> (; scale = config.scale, count = Ref(0)),
        makeworker = (idx, manager) -> ManagerFakeWorker(idx, Int[], false),
    )

    manager = ProcessManager(recipe; nworkers = 1, config = (; scale = 3))
    @test manager.config == (; scale = 3)
    @test manager.state.scale == 3
    @test manager.state.count[] == 0

    override_state = (; scale = 9)
    override_manager = ProcessManager(recipe; nworkers = 1, config = (; scale = 3), state = override_state)
    @test override_manager.state === override_state
end

@testset "ProcessManager keeps scheduling bounded by worker slots" begin
    active = Ref(0)
    max_active = Ref(0)
    recipe = (;
        makeworker = (idx, manager) -> ManagerFakeWorker(idx, Int[], false),
        prepare! = (slot, job, manager) -> push!(slot.worker.buffer, job),
        start! = (slot, job, manager) -> begin
            active[] += 1
            max_active[] = max(max_active[], active[])
            slot.worker.done = false
        end,
        isdone = (slot, manager) -> slot.worker.done,
        finalize! = (slot, job, manager) -> begin
            slot.worker.done = false
            active[] -= 1
        end,
    )

    manager = ProcessManager(recipe; nworkers = 2, flush_policy = NoFlush())
    dispatch!(manager, 1)
    dispatch!(manager, 2)
    @test max_active[] == 2

    slots(manager)[1].worker.done = true
    dispatch!(manager, 3)
    @test max_active[] == 2
    @test manager.dispatched == 3

    for slot in slots(manager)
        slot.worker.done = true
    end
    drain!(manager)
    @test active[] == 0
end

@testset "ProcessManager tracks active slots without slot scans" begin
    recipe = (;
        makeworker = (idx, manager) -> ManagerFakeWorker(idx, Int[], false),
        start! = (slot, job, manager) -> (slot.worker.done = false),
        isdone = (slot, manager) -> slot.worker.done,
        finalize! = (slot, job, manager) -> (slot.worker.done = false),
    )

    manager = ProcessManager(recipe; nworkers = 3, flush_policy = NoFlush())
    first_slot = dispatch!(manager, 1)
    second_slot = dispatch!(manager, 2)
    @test manager.active_count == 2
    @test manager.free_hint == 3

    first_slot.worker.done = true
    poll!(manager)
    @test manager.active_count == 1
    @test manager.free_hint == first_slot.idx

    reused_slot = dispatch!(manager, 3)
    @test reused_slot === first_slot
    @test manager.active_count == 2

    for slot in slots(manager)
        slot.worker.done = true
    end
    drain!(manager)
    @test manager.active_count == 0
    @test !any(slot.active for slot in slots(manager))
    @test second_slot.runs == 1
end

@testset "FlushAtEnd syncs worker-local buffers after drain" begin
    external = Int[]
    flush_count = Ref(0)
    manager = ProcessManager(immediate_fake_recipe(external, flush_count); nworkers = 2)

    for job in 1:5
        dispatch!(manager, job)
        poll!(manager)
    end

    @test isempty(external)
    @test manager.completions == 5
    drain!(manager)
    @test sort(external) == collect(1:5)
    @test flush_count[] == 1
end

@testset "wait finishes active ProcessManager work without final flush" begin
    external = Int[]
    flush_count = Ref(0)
    manager = ProcessManager(immediate_fake_recipe(external, flush_count); nworkers = 2)

    dispatch!(manager, 1)
    dispatch!(manager, 2)

    @test wait(manager) === manager
    @test manager.active_count == 0
    @test isempty(external)
    @test sort(vcat((slot.worker.buffer for slot in slots(manager))...)) == [1, 2]
    @test flush_count[] == 0

    drain!(manager)
    @test sort(external) == [1, 2]
    @test flush_count[] == 1
end

@testset "NoFlush leaves worker-local buffers untouched" begin
    external = Int[]
    flush_count = Ref(0)
    manager = ProcessManager(immediate_fake_recipe(external, flush_count); nworkers = 2, flush_policy = NoFlush())

    run!(manager, 1:4)

    @test isempty(external)
    @test flush_count[] == 0
    @test sort(vcat((slot.worker.buffer for slot in slots(manager))...)) == collect(1:4)
end

@testset "FlushEvery flushes by completed worker runs" begin
    external = Int[]
    flush_count = Ref(0)
    manager = ProcessManager(immediate_fake_recipe(external, flush_count); nworkers = 2, flush_policy = FlushEvery(2; drain = false))

    run!(manager, 1:5)

    @test sort(external) == collect(1:5)
    @test flush_count[] == 3
end

@testset "ProcessManager threaded mode supports thread schedule traits" begin
    external = Int[]
    flush_count = Ref(0)
    static_workers = Threads.maxthreadid()
    manager = ProcessManager(
        immediate_fake_recipe(external, flush_count);
        nworkers = static_workers,
        flush_policy = FlushAtEnd(),
        job_type = Int,
    )

    static_jobs = 1:(3 * static_workers)
    run!(manager, static_jobs, Static())

    @test Static() isa ThreadsType
    @test Dynamic() isa ThreadsType
    @test Greedy() isa ThreadsType
    @test sort(external) == collect(static_jobs)
    @test flush_count[] == 1
    @test manager.dispatched == length(static_jobs)
    @test manager.completions == length(static_jobs)
    @test manager.active_count == 0

    greedy_external = Int[]
    greedy_flush_count = Ref(0)
    greedy_manager = ProcessManager(
        immediate_fake_recipe(greedy_external, greedy_flush_count);
        nworkers = 2,
        flush_policy = FlushAtEnd(),
        job_type = Int,
    )

    runthreaded!(greedy_manager, 1:5, Greedy())

    @test sort(greedy_external) == collect(1:5)
    @test greedy_flush_count[] == 1
    @test greedy_manager.completions == 5
end

@testset "release! runs after consume!" begin
    events = Symbol[]
    recipe = (;
        makeworker = (idx, manager) -> ManagerFakeWorker(idx, Int[], false),
        prepare! = (slot, job, manager) -> push!(slot.worker.buffer, job),
        start! = (slot, job, manager) -> (slot.worker.done = true),
        isdone = (slot, manager) -> slot.worker.done,
        finalize! = (slot, job, manager) -> (slot.worker.done = false),
        consume! = (slot, job, manager) -> push!(events, :consume),
        release! = (slot, job, manager) -> begin
            push!(events, :release)
            empty!(slot.worker.buffer)
        end,
    )

    manager = ProcessManager(recipe; nworkers = 1, flush_policy = NoFlush())
    run!(manager, [1])

    @test events == [:consume, :release]
    @test isempty(only(slots(manager)).worker.buffer)
end

struct ManagerProcessAccumulator <: StatefulAlgorithms.ProcessAlgorithm end

function StatefulAlgorithms.init(::ManagerProcessAccumulator, context)
    value = get(context, :start, 0)
    return (; value = Ref(value), buffer = Int[])
end

function StatefulAlgorithms.step!(::ManagerProcessAccumulator, context)
    push!(context.buffer, context.value[])
    return (;)
end

struct ManagerProcessMultiplier <: StatefulAlgorithms.ProcessAlgorithm end

function StatefulAlgorithms.init(::ManagerProcessMultiplier, context::C) where {C}
    value = get(context, :start, 0)
    return (; value = Ref(value), buffer = Int[])
end

function StatefulAlgorithms.step!(::ManagerProcessMultiplier, context::C) where {C}
    push!(context.buffer, 2 * context.value[])
    return (;)
end

function manager_process_context(worker)
    subcontexts = StatefulAlgorithms.get_subcontexts(StatefulAlgorithms.context(worker))
    names = filter(!=(:globals), fieldnames(typeof(subcontexts)))
    return getproperty(subcontexts, only(names))
end

@testset "ProcessManager default Process copies share type but not context" begin
    make_count = Ref(0)
    recipe = (;
        makeworker = (idx, manager) -> begin
            make_count[] += 1
            Process(ManagerProcessAccumulator(); repeats = 1)
        end,
    )

    manager = ProcessManager(recipe; nworkers = 3, flush_policy = NoFlush())
    manager_slots = slots(manager)

    @test make_count[] == 1
    @test allequal(typeof(getalgo(slot.worker)) for slot in manager_slots)
    @test allequal(typeof(slot.worker) for slot in manager_slots)
    @test allequal(typeof(StatefulAlgorithms.context(slot.worker)) for slot in manager_slots)
    @test length(unique(objectid(StatefulAlgorithms.context(slot.worker)) for slot in manager_slots)) == 3
end

@testset "ProcessManager can build per-slot Process contexts" begin
    make_count = Ref(0)
    context_count = Ref(0)
    recipe = (;
        makeworker = (idx, manager) -> begin
            make_count[] += 1
            Process(
                ManagerProcessAccumulator,
                Input(ManagerProcessAccumulator, :start => 0);
                repeats = 1,
            )
        end,
        makecontext = (idx, manager, template) -> begin
            context_count[] += 1
            initialized = init(
                getalgo(template),
                Input(ManagerProcessAccumulator, :start => idx),
            )
            StatefulAlgorithms.context(initialized)
        end,
    )

    manager = ProcessManager(recipe; nworkers = 3, flush_policy = NoFlush())
    manager_slots = slots(manager)
    contexts = map(slot -> manager_process_context(slot.worker), manager_slots)

    @test make_count[] == 1
    @test context_count[] == 3
    @test allequal(typeof(getalgo(slot.worker)) for slot in manager_slots)
    @test allequal(typeof(StatefulAlgorithms.context(slot.worker)) for slot in manager_slots)
    @test length(unique(objectid(StatefulAlgorithms.context(slot.worker)) for slot in manager_slots)) == 3
    @test [ctx.value[] for ctx in contexts] == [1, 2, 3]
end

@testset "ProcessManager can uniquely init Process workers without deepcopy" begin
    make_count = Ref(0)
    worker_data = [3, 5, 8]
    recipe = (;
        makeworker = (idx, manager, initdata) -> begin
            make_count[] += 1
            Process(
                ManagerProcessAccumulator,
                Input(ManagerProcessAccumulator, :start => initdata);
                repeats = 1,
            )
        end,
    )

    manager = ProcessManager(
        recipe;
        nworkers = 3,
        worker_init = MakeEachWorker(),
        worker_init_data = worker_data,
        flush_policy = NoFlush(),
    )
    manager_slots = slots(manager)
    contexts = map(slot -> manager_process_context(slot.worker), manager_slots)

    @test make_count[] == 3
    @test length(unique(objectid(StatefulAlgorithms.context(slot.worker)) for slot in manager_slots)) == 3
    @test [ctx.value[] for ctx in contexts] == worker_data
end

@testset "ProcessManager can create on-demand workers for each job and keep the last worker" begin
    created = Int[]
    finalized = Int[]
    consumed = Int[]
    released = Int[]
    construction_count = Ref(0)
    recipe = (;
        makeworker = (idx, manager, job) -> begin
            construction_count[] += 1
            push!(created, job.value)
            ManagerFakeWorker(job.value, Int[], false)
        end,
        workername = (idx, manager, job) -> job.name,
        prepare! = (slot, job, manager) -> push!(slot.worker.buffer, job.value),
        start! = (slot, job, manager) -> (slot.worker.done = true),
        isdone = (slot, manager) -> slot.worker.done,
        workerfinalizer = (slot, job, manager) -> job.finalizer,
        consume! = (slot, job, manager) -> push!(consumed, only(slot.worker.buffer)),
        release! = (slot, job, manager) -> push!(released, slot.worker.idx),
    )
    jobs = [
        (; name = :trial_a, value = 3, finalizer = worker -> (push!(finalized, worker.idx); worker.done = false; worker)),
        (; name = :trial_b, value = 5, finalizer = (worker, slot, job) -> (push!(finalized, job.value); worker.done = false; worker)),
    ]

    manager = ProcessManager(
        recipe;
        nworkers = 1,
        worker_lifecycle = OnDemandWorkers(destroy_after_finalize = false),
        flush_policy = NoFlush(),
        job_type = eltype(jobs),
        result_type = ManagerFakeWorker,
    )
    @test construction_count[] == 0
    run!(manager, jobs)

    @test construction_count[] == 2
    @test created == [3, 5]
    @test finalized == [3, 5]
    @test consumed == [3, 5]
    @test released == [3, 5]
    @test only(slots(manager)).name == :trial_b
    @test only(workers(manager)).idx == 5
end

@testset "ProcessManager can destroy on-demand workers after release" begin
    destroyed = Int[]
    recipe = (;
        makeworker = (idx, manager, job) -> ManagerFakeWorker(job, Int[], false),
        prepare! = (slot, job, manager) -> push!(slot.worker.buffer, job),
        start! = (slot, job, manager) -> (slot.worker.done = true),
        isdone = (slot, manager) -> slot.worker.done,
        workerfinalizer = (slot, job, manager) -> worker -> (worker.done = false; worker),
        destroyworker! = (slot, job, manager) -> push!(destroyed, slot.worker.idx),
    )

    manager = ProcessManager(
        recipe;
        nworkers = 1,
        worker_lifecycle = OnDemandWorkers(),
        flush_policy = NoFlush(),
        job_type = Int,
        result_type = ManagerFakeWorker,
    )
    run!(manager, 7:9)

    @test destroyed == [7, 8, 9]

    closed = Int[]
    close_recipe = (;
        makeworker = recipe.makeworker,
        prepare! = recipe.prepare!,
        start! = recipe.start!,
        isdone = recipe.isdone,
        workerfinalizer = recipe.workerfinalizer,
        close! = (slot, manager) -> push!(closed, slot.worker.idx),
    )
    close_manager = ProcessManager(
        close_recipe;
        nworkers = 1,
        worker_lifecycle = OnDemandWorkers(),
        flush_policy = NoFlush(),
        job_type = Int,
        result_type = ManagerFakeWorker,
    )
    run!(close_manager, [11])

    @test closed == [11]
end

@testset "ProcessManager can use job-specific Process algorithm types" begin
    outputs = Int[]
    recipe = (;
        makeworker = (idx, manager, job) -> Process(job.algo; repeats = 1),
        workername = (idx, manager, job) -> job.name,
        prepare! = (slot, job, manager) -> begin
            local_context = manager_process_context(slot.worker)
            local_context.value[] = job.value
            nothing
        end,
        consume! = (slot, job, manager) -> begin
            local_context = manager_process_context(slot.worker)
            push!(outputs, only(local_context.buffer))
        end,
    )
    jobs = Any[
        (; name = :accumulate, algo = ManagerProcessAccumulator(), value = 4),
        (; name = :multiply, algo = ManagerProcessMultiplier(), value = 4),
    ]

    manager = ProcessManager(
        recipe;
        nworkers = 1,
        worker_lifecycle = OnDemandWorkers(destroy_after_finalize = false),
        worker_type = Process,
        flush_policy = NoFlush(),
        job_type = Any,
        result_type = Process,
    )
    run!(manager, jobs)

    @test outputs == [4, 8]
    @test only(slots(manager)).name == :multiply
    @test only(workers(manager)) isa Process
    @test_throws ArgumentError ProcessManager(
        recipe;
        nworkers = 1,
        worker_lifecycle = OnDemandWorkers(),
        worker_type = :process,
    )
end

@testset "Process workers are transparent and reset is explicit" begin
    worker = Process(ManagerProcessAccumulator(); repeats = 1)
    external = Int[]
    reset_calls = Ref(0)
    recipe = (;
        prepare! = (slot, job, manager) -> begin
            local_context = manager_process_context(slot.worker)
            local_context.value[] = job
        end,
        flush! = manager -> begin
            for slot in slots(manager)
                local_context = manager_process_context(slot.worker)
                append!(external, local_context.buffer)
                empty!(local_context.buffer)
            end
        end,
    )

    manager = ProcessManager(recipe; workers = [worker])
    run!(manager, 1:3)

    @test external == [1, 2, 3]
    @test reset_calls[] == 0

    reset_recipe = (;
        prepare! = (slot, job, manager) -> begin
            reset_calls[] += 1
            resetworker!(slot)
            local_context = manager_process_context(slot.worker)
            local_context.value[] = job
        end,
        flush! = recipe.flush!,
    )

    reset_manager = ProcessManager(reset_recipe; workers = [worker])
    run!(reset_manager, 4:5)

    @test reset_calls[] == 2
end

@testset "Process workers can run inline to avoid task churn" begin
    worker = Process(ManagerProcessAccumulator(); repeats = 1)
    external = Int[]
    recipe = (;
        prepare! = (slot, job, manager) -> begin
            local_context = manager_process_context(slot.worker)
            local_context.value[] = job
            nothing
        end,
        start! = (slot, job, manager) -> runprocessinline!(slot.worker),
        isdone = (slot, manager) -> true,
        finalize! = (slot, job, manager) -> nothing,
        consume! = (slot, job, manager) -> begin
            local_context = manager_process_context(slot.worker)
            push!(external, only(local_context.buffer))
            empty!(local_context.buffer)
        end,
    )

    manager = ProcessManager(recipe; workers = (worker,), flush_policy = NoFlush(), job_type = Int, result_type = Nothing)
    run!(manager, 1:3)

    @test external == [1, 2, 3]
    @test manager.active_count == 0
    @test isnothing(worker.task)
end

@testset "ProcessManager runarguments can set per-job Process lifetime" begin
    jobs = [
        (; value = 1, repeats = 2),
        (; value = 2, lifetime = Repeat(3)),
    ]

    polling_worker = Process(ManagerProcessAccumulator(); repeats = 1)
    polling_output = Int[]
    polling_recipe = (;
        prepare! = (slot, job, manager) -> begin
            local_context = manager_process_context(slot.worker)
            local_context.value[] = job.value
            nothing
        end,
        runarguments = (slot, job, manager) -> haskey(job, :repeats) ? (; repeats = job.repeats) : (; lifetime = job.lifetime),
        consume! = (slot, job, manager) -> begin
            local_context = manager_process_context(slot.worker)
            append!(polling_output, local_context.buffer)
            empty!(local_context.buffer)
        end,
    )
    polling_manager = ProcessManager(polling_recipe; workers = (polling_worker,), flush_policy = NoFlush())
    run!(polling_manager, jobs)

    @test polling_output == [1, 1, 2, 2, 2]
    @test isnothing(polling_worker.task)

    threaded_template = Process(ManagerProcessAccumulator(); repeats = 1)
    threaded_output = Int[]
    threaded_recipe = (;
        makeworker = (idx, manager) -> copyprocess(threaded_template; context = deepcopy(context(threaded_template))),
        prepare! = polling_recipe.prepare!,
        runarguments = polling_recipe.runarguments,
        flush! = manager -> begin
            for slot in slots(manager)
                local_context = manager_process_context(slot.worker)
                append!(threaded_output, local_context.buffer)
                empty!(local_context.buffer)
            end
        end,
    )
    threaded_manager = ProcessManager(threaded_recipe; nworkers = 2, flush_policy = FlushAtEnd())
    runthreaded!(threaded_manager, jobs, Dynamic())

    @test sort(threaded_output) == [1, 1, 2, 2, 2]
    @test all(isnothing(slot.worker.task) for slot in slots(threaded_manager))
end

@testset "ProcessManager threaded mode runs Process workers inline" begin
    template = Process(ManagerProcessAccumulator(); repeats = 1)
    external = Int[]
    recipe = (;
        makeworker = (idx, manager) -> copyprocess(template; context = deepcopy(StatefulAlgorithms.context(template))),
        prepare! = (slot, job, manager) -> begin
            local_context = manager_process_context(slot.worker)
            local_context.value[] = job
            nothing
        end,
        flush! = manager -> begin
            for slot in slots(manager)
                local_context = manager_process_context(slot.worker)
                append!(external, local_context.buffer)
                empty!(local_context.buffer)
            end
        end,
    )

    manager = ProcessManager(recipe; nworkers = 2, flush_policy = FlushAtEnd(), job_type = Int)
    runthreaded!(manager, 1:4, Dynamic())

    @test sort(external) == collect(1:4)
    @test manager.completions == 4
    @test all(isnothing(slot.worker.task) for slot in slots(manager))
end

@testset "ProcessManager channel mode keeps worker tasks online until jobs drain" begin
    template = Process(ManagerProcessAccumulator(); repeats = 1)
    external = Int[]
    recipe = (;
        makeworker = (idx, manager) -> copyprocess(template; context = deepcopy(StatefulAlgorithms.context(template))),
        prepare! = (slot, job, manager) -> begin
            local_context = manager_process_context(slot.worker)
            local_context.value[] = job
            nothing
        end,
        flush! = manager -> begin
            for slot in slots(manager)
                local_context = manager_process_context(slot.worker)
                append!(external, local_context.buffer)
                empty!(local_context.buffer)
            end
        end,
    )

    manager = ProcessManager(recipe; nworkers = 2, flush_policy = FlushAtEnd(), job_type = Int)
    run!(manager, 1:6, ChannelWorkers(; channel_size = 2))

    @test sort(external) == collect(1:6)
    @test manager.dispatched == 6
    @test manager.completions == 6
    @test manager.active_count == 0
    @test sum(slot.runs for slot in slots(manager)) == 6
    @test all(isnothing(slot.worker.task) for slot in slots(manager))
end

@testset "ProcessManager channel mode can consume an externally closed channel" begin
    template = Process(ManagerProcessAccumulator(); repeats = 1)
    external = Int[]
    recipe = (;
        makeworker = (idx, manager) -> copyprocess(template; context = deepcopy(StatefulAlgorithms.context(template))),
        prepare! = (slot, job, manager) -> begin
            local_context = manager_process_context(slot.worker)
            local_context.value[] = job
            nothing
        end,
        flush! = manager -> begin
            for slot in slots(manager)
                local_context = manager_process_context(slot.worker)
                append!(external, local_context.buffer)
                empty!(local_context.buffer)
            end
        end,
    )

    jobs = Channel{Int}(1)
    producer = Threads.@spawn begin
        try
            for job in 1:5
                put!(jobs, job)
            end
        finally
            close(jobs)
        end
    end

    manager = ProcessManager(recipe; nworkers = 3, flush_policy = FlushAtEnd(), job_type = Int)
    run!(manager, jobs, ChannelWorkers())
    fetch(producer)

    @test sort(external) == collect(1:5)
    @test manager.dispatched == 5
    @test manager.completions == 5
    @test all(isnothing(slot.worker.task) for slot in slots(manager))
end

@testset "reinitworker! rebuilds Process context through init pipeline" begin
    worker = Process(
        ManagerProcessAccumulator,
        Input(ManagerProcessAccumulator, :start => 0);
        repeats = 1,
    )
    external = Int[]
    recipe = (;
        prepare! = (slot, job, manager) -> reinitworker!(
            slot,
            Input(ManagerProcessAccumulator, :start => job),
        ),
        consume! = (slot, job, manager) -> begin
            local_context = manager_process_context(slot.worker)
            append!(external, local_context.buffer)
        end,
    )

    manager = ProcessManager(recipe; workers = [worker], flush_policy = NoFlush())
    run!(manager, [2, 5])

    @test external == [2, 5]
end

@ProcessAlgorithm function ManagerRuntimeJobStep(
    delta,
    @managed(total = base);
    @inputs((; base = 0))
)
    total += delta
    return (; total)
end

@testset "ProcessManager recipe steps can prepare context and pass runtime inputs" begin
    algo = @CompositeAlgorithm begin
        @input delta::Int
        ManagerRuntimeJobStep(delta = delta)
    end
    worker = Process(algo, Init(ManagerRuntimeJobStep; base = 0); repeats = 1)
    outputs = Int[]
    before_jobs = Int[]
    jobs = [
        (; base = 10, delta = 1),
        (; base = 20, delta = 2),
    ]
    recipe = (;
        prepare! = (slot, job, manager) -> partialinitworker!(
            slot,
            Init(ManagerRuntimeJobStep; base = job.base),
        ),
        runarguments = (slot, job, manager) -> begin
            push!(before_jobs, job.base)
            (; delta = job.delta)
        end,
        consume! = (slot, job, manager) -> push!(
            outputs,
            context(slot.worker)[ManagerRuntimeJobStep].total,
        ),
    )

    manager = ProcessManager(recipe; workers = [worker], flush_policy = NoFlush())
    run!(manager, jobs)

    @test outputs == [11, 22]
    @test before_jobs == [10, 20]
end

@testset "ProcessManager rejects non-keyword runarguments results" begin
    worker = Process(ManagerProcessAccumulator(); repeats = 1)
    recipe = (;
        runarguments = (slot, job, manager) -> job,
    )
    manager = ProcessManager(recipe; workers = [worker], flush_policy = NoFlush(), throw = false)

    dispatch!(manager, 1)

    @test manager.dispatched == 0
    @test only(slots(manager)).error isa ArgumentError
end

struct ManagerInlineAccumulator <: StatefulAlgorithms.ProcessAlgorithm end

function StatefulAlgorithms.init(::ManagerInlineAccumulator, context::C) where {C}
    return (; value = Ref(0), total = Ref(0))
end

function StatefulAlgorithms.step!(::ManagerInlineAccumulator, context::C) where {C}
    context.total[] += context.value[]
    return (;)
end

function manager_inline_context(worker::W) where {W<:InlineChunkWorker}
    subcontexts = StatefulAlgorithms.get_subcontexts(StatefulAlgorithms.context(worker.process))
    names = filter(!=(:globals), fieldnames(typeof(subcontexts)))
    return getproperty(subcontexts, only(names))
end

@testset "ProcessManager can run InlineProcess workers by chunks" begin
    worker = InlineChunkWorker(InlineProcess(ManagerInlineAccumulator(); repeats = 1))
    outputs = Int[]
    chunk_lengths = Int[]
    recipe = (;
        beforechunk! = (process, chunk, slot, manager) -> push!(chunk_lengths, length(chunk)),
        resetexample! = (process, example, slot, manager) -> begin
            local_context = manager_inline_context(slot.worker)
            local_context.total[] = 0
            nothing
        end,
        loadexample! = (process, example, slot, manager) -> begin
            local_context = manager_inline_context(slot.worker)
            local_context.value[] = example
            nothing
        end,
        afterexample! = (process, example, result, slot, manager) -> begin
            local_context = manager_inline_context(slot.worker)
            push!(outputs, local_context.total[])
            nothing
        end,
    )

    manager = ProcessManager(
        recipe;
        workers = (worker,),
        flush_policy = NoFlush(),
        job_type = Vector{Int},
        result_type = typeof(worker),
    )
    runchunks!(manager, 1:5; chunksize = 2)

    @test outputs == collect(1:5)
    @test chunk_lengths == [2, 2, 1]
    @test worker.runs == 5
    @test manager.dispatched == 3
    @test isnothing(worker.task)
end

@testset "Inline chunk workers support threaded manager schedules" begin
    outputs = Int[]
    recipe = (;
        makeworker = (idx, manager) -> InlineChunkWorker(InlineProcess(ManagerInlineAccumulator(); repeats = 1)),
        beforechunk! = (process, chunk, slot, manager) -> begin
            isnothing(slot.scratch) && (slot.scratch = Int[])
            nothing
        end,
        resetexample! = (process, example, slot, manager) -> begin
            local_context = manager_inline_context(slot.worker)
            local_context.total[] = 0
            nothing
        end,
        loadexample! = (process, example, slot, manager) -> begin
            local_context = manager_inline_context(slot.worker)
            local_context.value[] = example
            nothing
        end,
        afterexample! = (process, example, result, slot, manager) -> begin
            local_context = manager_inline_context(slot.worker)
            push!(slot.scratch, local_context.total[])
            nothing
        end,
        flush! = manager -> begin
            for slot in slots(manager)
                isnothing(slot.scratch) && continue
                append!(outputs, slot.scratch)
                empty!(slot.scratch)
            end
        end,
    )

    manager = ProcessManager(
        recipe;
        nworkers = 2,
        flush_policy = FlushAtEnd(),
        job_type = Vector{Int},
        scratch_type = Vector{Int},
        result_type = InlineChunkWorker,
    )
    runchunks!(manager, 1:6, Dynamic(); chunksize = 2)

    @test sort(outputs) == collect(1:6)
    @test sum(slot.worker.runs for slot in slots(manager)) == 6
    @test manager.dispatched == 3
    @test manager.completions == 3
    @test all(isnothing(slot.worker.task) for slot in slots(manager))
end

@testset "Inline chunk workers keep context between examples unless recipe resets" begin
    worker = InlineChunkWorker(InlineProcess(ManagerInlineAccumulator(); repeats = 1))
    totals = Int[]
    recipe = (;
        loadexample! = (process, example, slot, manager) -> begin
            local_context = manager_inline_context(slot.worker)
            local_context.value[] = example
            nothing
        end,
        afterexample! = (process, example, result, slot, manager) -> begin
            local_context = manager_inline_context(slot.worker)
            push!(totals, local_context.total[])
            nothing
        end,
    )

    manager = ProcessManager(
        recipe;
        workers = (worker,),
        flush_policy = NoFlush(),
        job_type = Vector{Int},
        result_type = typeof(worker),
    )
    runchunks!(manager, 1:3; chunksize = 3)

    @test totals == [1, 3, 6]
    @test manager.dispatched == 1
end
