# [Process Managers](@id threaded_process_managers_user)

```@meta
CurrentModule = StatefulAlgorithms
```

Use a `ProcessManager` when you already have a worker definition and want to run
many independent jobs through a bounded set of reusable workers. For normal
`StatefulAlgorithms.jl` usage, each worker is usually a reusable `Process`, but managers
can also wrap custom worker objects.

The current manager API separates two ideas:

- a portable recipe core that describes how one job is loaded, run, read, and
  synchronized;
- an execution mode stored on the manager that decides how workers are
  scheduled.

```julia
manager = ProcessManager(recipe; nworkers = 4, execution = ThreadedWorkers(Dynamic()))
run!(manager, jobs)
```

Do not pass execution modes to `run!`. Construct the manager with the execution
mode you want, then call `run!(manager, jobs)`.

## Terms

- A **job** is one item of work, such as one sample, trajectory, or simulation
  case.
- A **worker** is the reusable object that handles one job at a time.
- A **slot** is the manager record around one worker. It stores the worker, the
  current job, the latest result, and the latest error.
- A **recipe** tells the manager how to create workers and how each job should
  interact with one worker.
- `manager.state` is manager-owned runtime data, commonly used for output
  buffers, counters, shared parameters, and optimizer state.

## Portable Recipe Core

The standard lifecycle calls these recipe callbacks:

```julia
loadjob!(recipe, slot, job, manager)
providearguments(recipe, slot, job, manager)
afterjob!(recipe, slot, job, manager)
sync_to_state!(recipe, manager)
```

As named tuple fields:

```julia
recipe = (;
    makeworker = (idx, manager) -> Process(MyAlgo; repeats = 1),

    loadjob! = (slot, job, manager) -> begin
        ctx = context(slot.worker)[MyAlgo]
        ctx.value[] = job.value
        resetworker!(slot)
    end,

    providearguments = (slot, job, manager) -> (;),

    afterjob! = (slot, job, manager) -> begin
        ctx = context(slot.worker)[MyAlgo]
        push!(ctx.local_outputs, ctx.output[])
    end,

    sync_to_state! = manager -> begin
        for slot in slots(manager)
            ctx = context(slot.worker)[MyAlgo]
            append!(manager.state.outputs, ctx.local_outputs)
            empty!(ctx.local_outputs)
        end
    end,
)
```

`loadjob!` is the normal place to write job data into `context(slot.worker)` and
reset the worker. `providearguments` returns runtime keyword arguments for the
worker run; return `nothing` or omit it if no runtime arguments are needed.
`afterjob!` reads one finished worker. `sync_to_state!` merges worker-local state
into `manager.state` or another shared destination according to the manager's
sync policy.

The standard lifecycle does not fall back to old names such as `prepare!`,
`runarguments`, `consume!`, or `flush!`. Those names are kept only as
compatibility lookup functions and should not be used for new portable recipes.

## Execution Modes

Execution mode is stored on the manager:

```julia
ProcessManager(recipe; execution = PollingWorkers())
ProcessManager(recipe; execution = ThreadedWorkers(Dynamic()))
ProcessManager(recipe; execution = ThreadedWorkers(Static()))
ProcessManager(recipe; execution = ThreadedWorkers(Greedy()))
ProcessManager(recipe; execution = ChannelWorkers(; channel_size = 8))
```

If `execution` is omitted, the manager uses `PollingWorkers()`. A recipe can also
provide a default execution field:

```julia
recipe = (;
    execution = ChannelWorkers(),
    makeworker = (idx, manager) -> Process(MyAlgo; repeats = 1),
    loadjob! = (slot, job, manager) -> nothing,
)

manager = ProcessManager(recipe)
```

`PollingWorkers()` uses the original dispatch/poll/drain scheduler.
`ThreadedWorkers(schedule)` runs jobs through `Threads.@threads` and runs
default `Process` workers inline to avoid one task spawn per job.
`ChannelWorkers()` starts one long-lived worker task per slot and lets workers
pull jobs from a channel until the job stream closes.

`run!(manager, jobs, Dynamic())`, `run!(manager, jobs, Static())`,
`run!(manager, jobs, Greedy())`, and `run!(manager, jobs, ChannelWorkers())`
throw an `ArgumentError`. Put the mode in `ProcessManager(...; execution = ...)`
instead.

The direct helpers `runthreaded!` and `runchannel!` remain available as lower
level escape hatches, but normal user-facing code should prefer manager-owned
execution and plain `run!(manager, jobs)`.

## Sync Policies

`sync_policy` controls when `sync_to_state!(recipe, manager)` is called:

```julia
ProcessManager(recipe; sync_policy = SyncAtEnd())
ProcessManager(recipe; sync_policy = NoSync())
ProcessManager(recipe; sync_policy = SyncEvery(32; drain = true))
```

- `SyncAtEnd()` is the default. It runs all jobs, drains active workers, then
  calls `sync_to_state!` once.
- `NoSync()` never calls `sync_to_state!` automatically.
- `SyncEvery(n; drain = true)` calls `sync_to_state!` after every `n` completed
  worker runs. With `drain = true`, active workers are finalized before syncing.

Use `afterjob!` for per-job result reads. Use `sync_to_state!` when results or
worker-local buffers should be merged in batches.

The old names `FlushAtEnd`, `NoFlush`, `FlushEvery`, and the constructor keyword
`flush_policy` are compatibility aliases. New code should use `SyncAtEnd`,
`NoSync`, `SyncEvery`, and `sync_policy`.

## Manager State

`manager.state` is shared manager-owned data. Worker context is slot-local:

- use `manager.state` for shared parameters, output buffers, counters, optimizer
  state, and history;
- use `context(slot.worker)` for the current job, worker-local buffers, and
  temporary state.

Build manager state with `initstate`:

```julia
recipe = (;
    initstate = config -> (;
        params = Ref(config.initial_params),
        outputs = Float64[],
    ),
    makeworker = (idx, manager) -> Process(MyAlgo; repeats = 1),
)

manager = ProcessManager(
    recipe;
    config = (; initial_params = (w = 0.0, b = 0.0)),
)
```

or pass it directly:

```julia
manager = ProcessManager(recipe; state = (; outputs = Float64[]))
```

## Worker Ownership

The usual form lets the manager create and own workers:

```julia
recipe = (;
    makeworker = (idx, manager) -> Process(MyAlgo; repeats = 1),
    loadjob! = (slot, job, manager) -> begin
        ctx = context(slot.worker)[MyAlgo]
        ctx.value[] = job.value
        resetworker!(slot)
    end,
)

manager = ProcessManager(recipe; nworkers = 4)
```

If `workers = ...` is passed, the manager wraps existing workers and does not
create new contexts:

```julia
manager = ProcessManager(recipe; workers = existing_workers)
```

For manager-owned `Process` workers, `makecontext` can build separate per-slot
contexts while sharing one worker template:

```julia
recipe = (;
    makeworker = (idx, manager) -> Process(MyAlgo; repeats = 1),
    makecontext = (idx, manager, template) -> begin
        initialized = init(getalgo(template), Init(MyAlgo; seed = idx))
        context(initialized)
    end,
)
```

Inspect slots and workers with:

```julia
slots(manager)
workers(manager)
```

Closing an owning manager closes its workers:

```julia
close(manager)
```

## On-Demand Workers

Use `OnDemandWorkers()` when each job should construct its own worker:

```julia
recipe = (;
    initstate = config -> (; results = []),
    workername = (idx, manager, job) -> job.name,
    makeworker = (idx, manager, job) -> Process(
        job.algo,
        Init(job.algo; seed = job.seed);
        repeats = 1,
    ),
    afterjob! = (slot, job, manager) -> push!(
        manager.state.results,
        (; name = slot.name, output = job.readout(slot.worker)),
    ),
)

manager = ProcessManager(
    recipe;
    nworkers = 4,
    worker_lifecycle = OnDemandWorkers(destroy_after_finalize = false),
    worker_type = Process,
)
```

Pass `worker_type` when different jobs may return different concrete worker
types. Use `destroy_after_finalize = false` if the last finished worker should
remain in the slot for inspection.

## Execution-Specific Hooks

The portable recipe core works across polling, threaded, and channel execution
modes. Advanced callbacks can take over parts of the execution protocol:

- `start!(slot, job, manager)` replaces the default worker launch.
- `isdone(slot, manager)` customizes polling completion checks.
- `finalize!(slot, job, manager)` replaces default worker finalization.
- `workerfinalizer(slot, job, manager)` chooses a per-job finalizer.

These hooks are execution-specific. In particular, `isdone` is valid only with
`PollingWorkers()`, because threaded and channel workers own the job until it is
complete and do not poll per-job completion.

For normal result accumulation, prefer `afterjob!` over `finalize!`. Use
`finalize!` only when worker finalization itself must be customized.

## Runtime Inputs And Reinitialization

Use `loadjob!` for persistent context changes:

```julia
loadjob! = (slot, job, manager) -> begin
    ctx = context(slot.worker)[MyAlgo]
    ctx.value[] = job.value
    resetworker!(slot)
end
```

Use `providearguments` for loop-level runtime `@input` values:

```julia
providearguments = (slot, job, manager) -> (; temperature = job.temperature)
```

For `Process` workers, `lifetime`, `repeats`, and `repeat` returned by
`providearguments` are launch controls. Other keys are passed as runtime
inputs.

Use `reinitworker!` when the whole worker context should be rebuilt through the
normal init pipeline:

```julia
loadjob! = (slot, job, manager) -> reinitworker!(
    slot,
    Input(MyAlgo, :start => job.start),
)
```

Use `partialinitworker!` when only selected context targets should be rebuilt:

```julia
loadjob! = (slot, job, manager) -> partialinitworker!(
    slot,
    Init(MyStep; base = job.base),
)
```

## Chunked Inline Workers

`runchunks!` remains a specialized batching path for `InlineChunkWorker`. It is
not part of the portable manager recipe core. Chunked recipes keep their
chunk-specific callback names:

- `beforechunk!`
- `resetexample!`
- `loadexample!`
- `afterexample!`
- `afterchunk!`

Use chunked inline workers when a chunk is semantically meaningful or when an
`InlineProcess` should process many examples inside one manager job. If the goal
is only to avoid per-job task spawning for ordinary `Process` workers, prefer
`ChannelWorkers()` or `ThreadedWorkers(...)`.

```julia
worker = InlineChunkWorker(InlineProcess(MyInlineAlgo; repeats = 1))

manager = ProcessManager(
    recipe;
    workers = (worker,),
    sync_policy = NoSync(),
    job_type = Vector{Int},
)

runchunks!(manager, dataset; chunksize = 128)
```

Threaded chunk scheduling still accepts a thread schedule directly:

```julia
runchunks!(manager, dataset, Dynamic(); chunksize = 128)
runchunks!(manager, dataset, Static(); chunksize = 128)
runchunks!(manager, dataset, Greedy(); chunksize = 128)
```

## Public API Reference

```@docs
StatefulAlgorithms.ProcessManager
StatefulAlgorithms.WorkerSlot
StatefulAlgorithms.PollingWorkers
StatefulAlgorithms.ThreadedWorkers
StatefulAlgorithms.ChannelWorkers
StatefulAlgorithms.SyncAtEnd
StatefulAlgorithms.NoSync
StatefulAlgorithms.SyncEvery
StatefulAlgorithms.loadjob!
StatefulAlgorithms.providearguments
StatefulAlgorithms.afterjob!
StatefulAlgorithms.sync_to_state!
StatefulAlgorithms.run!
StatefulAlgorithms.runchannel!
StatefulAlgorithms.runchunks!
StatefulAlgorithms.InlineChunkWorker
StatefulAlgorithms.OnDemandWorkers
StatefulAlgorithms.resetworker!
StatefulAlgorithms.reinitworker!
StatefulAlgorithms.partialinitworker!
StatefulAlgorithms.slots
StatefulAlgorithms.workers
```
