# [Threaded Process Managers](@id threaded_process_managers_user)

```@meta
CurrentModule = StatefulAlgorithms
```

Use a `ProcessManager` when you already have a `Process` definition and want to
run many independent jobs on Julia threads. The manager is not another way to
write algorithms. It is a runtime layer that reuses initialized processes,
loads one job into each process, runs those processes, and collects the results.

The main threaded entry point is:

```julia
runthreaded!(manager, jobs)
```

You can also pass a thread schedule explicitly:

```julia
run!(manager, jobs, Dynamic())
run!(manager, jobs, Static())
run!(manager, jobs, Greedy())
```

## Terms

- A **job** is one item of work, such as one sample, one trajectory, or one
  simulation case.
- A **managed process** is a reusable `Process` that handles one job at a time.
- A **slot** is the manager record for one managed process. It stores the
  process, the current job, the latest result, and any error from that run.
- A **recipe** tells the manager how to load jobs, run processes, collect
  outputs, and reset state between jobs.
- `manager.state` is manager-owned runtime data, commonly used for output
  buffers, counters, and shared parameters.

The API uses the word `worker` for a managed process because a manager can also
wrap non-`Process` worker objects. For ordinary threaded `StatefulAlgorithms.jl` usage,
read `worker` as "the reusable process in this slot".

## What `manager.state` Is

`manager.state` is one shared object stored on the manager itself. Every recipe
callback can read it, and callbacks that mutate it are mutating the same shared
object.

This is different from `context(slot.worker)`:

- `manager.state` is manager-wide state shared across all slots.
- `context(slot.worker)` is the current context of one specific worker process.

Use `manager.state` for data that should survive across many jobs and should be
visible to the manager as a whole. Common examples are:

- shared gradient buffers,
- current global model parameters,
- optimizer state,
- output arrays or logs,
- counters such as number of processed samples,
- statistics accumulated across workers.

Use worker context for data that belongs to one worker run or one worker-local
buffer. Examples are:

- the current job's input values,
- temporary per-worker accumulation buffers,
- one worker's random state,
- one worker's local scratch arrays.

In other words, if each worker should have its own copy, put it in the worker
context. If all workers and manager callbacks should refer to the same long-lived
object, put it in `manager.state`.

You can create `manager.state` in two ways:

1. Pass `state = your_state_object` directly to `ProcessManager(...)`.
2. Define `initstate(config, manager)` and let the manager build it from
   `config`.

These are equivalent in the final manager object. The only difference is where
the state object comes from.

### Why `manager.state` Is Useful

Without `manager.state`, shared training or batching logic has no single home.
You would have to keep external mutable objects next to the manager and close
over them manually in callbacks. That works, but it scatters the state outside
the manager.

With `manager.state`, the shared state is carried by the manager itself:

- `prepare!` can read shared parameters and load them into a worker,
- `consume!` can append one worker's result into a shared output array,
- `flush!` can merge all worker-local buffers and apply one shared update,
- later runs can continue from the updated shared state.

### Example: Shared Parameters

```julia
recipe = (;
    initstate = config -> (;
        params = Ref(config.initial_params),
        nsamples = Ref(0),
    ),

    prepare! = (slot, job, manager) -> begin
        ctx = context(slot.worker)[MyAlgo]
        ctx.params[] = manager.state.params[]
        ctx.x[] = job.x
        manager.state.nsamples[] += 1
        resetworker!(slot)
    end,
)
```

Here `manager.state.params` is the shared parameter value for the whole manager.
Each worker gets a copy of that value loaded into its own context before a run.
`manager.state.nsamples` counts all jobs seen by the manager, not just jobs seen
by one worker.

### Example: Shared Output Buffer

```julia
recipe = (;
    initstate = config -> (; outputs = Float64[]),

    consume! = (slot, job, manager) -> begin
        ctx = context(slot.worker)[MyAlgo]
        push!(manager.state.outputs, ctx.value[])
    end,
)
```

Here the output array belongs to the manager, not to any one worker. Each
finished worker appends one value into the shared output buffer.

## Whole Manager Workflow

A threaded manager run has four parts:

1. Construction creates the fixed slots. If you pass `workers = ...`, those
   process objects are wrapped as-is. If you omit `workers`, the recipe must
   define `makeworker`; the manager builds the processes for you. For `Process`
   workers, `makecontext` can build separate per-slot contexts while keeping
   the same algorithm.
2. Dispatch assigns one job to one available slot. The manager stores the job
   in `slot.job`, clears the previous `slot.result` and `slot.error`, runs
   `prepare!`, calls `runarguments`, then starts the process. Use `prepare!` for
   persistent context changes. Use `runarguments` for runtime `@input` values by
   returning a named tuple. For `Process` workers, `lifetime`, `repeats`, and
   `repeat` in that tuple control the launch lifetime; the remaining keys are
   passed as runtime inputs.
3. Completion happens inside the threaded job iteration. When a process
   finishes, the manager runs `finalize!`, `afterrun!`, `consume!`, and
   `release!`, then makes the slot available for another job.
4. Flushing is manager-level synchronization. `flush_policy` decides when
   `flush!` runs. Use `flush!` to merge slot-local buffers into `manager.state`,
   external storage, or another object.

In threaded mode, default `Process` workers run inline inside a
`Threads.@threads` iteration. This avoids one task spawn per job. Recipe
callbacks still run as part of the slot lifecycle, so `consume!` and `flush!`
remain the right places to move finished values out of process contexts.

The recipe is stored directly in `ProcessManager{Recipe,...}`. A named tuple of
closures therefore keeps the concrete closure types visible to Julia. For lower
overhead, also pass `job_type`, `result_type`, `scratch_type`, or `error_type`
when those slot field types are known.

## Worker Ownership

The usual form is to let the manager create and own its processes:

```julia
recipe = (;
    makeworker = (idx, manager) -> Process(MyAlgo; repeats = 1),

    prepare! = (slot, job, manager) -> begin
        ctx = context(slot.worker)[MyAlgo]
        ctx.value[] = job.value
        resetworker!(slot)
    end,
)

manager = ProcessManager(recipe; nworkers = 4)
```

In this form, `makeworker` is called when the manager is created. The manager
stores those processes and their contexts in `slots(manager)`. Later calls to
`runthreaded!(manager, jobs)` do not create new processes or new contexts unless
your recipe does so.

For `Process` workers, the manager can also build the algorithm once and let the
recipe build each process context separately:

```julia
recipe = (;
    makeworker = (idx, manager) -> Process(MyAlgo; repeats = 1),

    makecontext = (idx, manager, template) -> begin
        initialized = init(
            getalgo(template),
            Init(MyAlgo; seed = idx),
        )
        context(initialized)
    end,
)

manager = ProcessManager(recipe; nworkers = 4)
```

Here `makeworker` is still called once. `makecontext` is called once per slot,
including slot 1. The manager installs each returned context on a process that
uses the template task description. Use this when all processes should run the
same algorithm, but each process needs separate buffers, random state, or
initial values.

You can inspect manager-owned processes with:

```julia
slots(manager)
workers(manager)
```

Closing an owning manager also closes its processes:

```julia
close(manager)
```

You can also pass processes that were built elsewhere:

```julia
manager = ProcessManager(recipe; workers = existing_workers)
```

This wraps the existing processes in new slots. It does not create contexts.
Use this form when some other object owns the processes or when the processes
must be constructed before the manager exists.

## On-Demand Workers

Use `OnDemandWorkers` when the job should define the worker that runs it. This
is a different manager operation mode from reusable workers: slots are created
upfront, but workers are not. Each dispatched job calls
`makeworker(idx, manager, job)` and installs the returned worker into the slot.

This is useful for automating long lived experiments where the job record is the
experiment specification. For example, one job can carry the algorithm type,
initialization options, seed, output location, and a worker-specific finalizer.
The manager still gives you bounded threaded scheduling, error accounting,
flushing, and a consistent result collection lifecycle, but each experiment can
choose its own worker shape.

Slots also keep a `slot.name::Symbol`. By default names are `:worker_1`,
`:worker_2`, and so on. Define `workername(idx, manager, job)` when a job should
provide a stable experiment label, so later result lookup and logs can refer to
the same name.

```julia
recipe = (;
    initstate = config -> (; results = []),
    workername = (idx, manager, job) -> job.name,
    makeworker = (idx, manager, job) -> Process(
        job.algo,
        Init(job.algo; seed = job.seed);
        repeats = 1,
    ),
    workerfinalizer = (slot, job, manager) -> job.finalizer,
    consume! = (slot, job, manager) -> push!(
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
types. For `Process` workers, `Process(job.algo; ...)` usually has a concrete
type that depends on `job.algo`, so use `worker_type = Process` when jobs may
select different concrete `Process{LoopAlgo}` specializations. If every job
returns exactly the same worker type, pass that concrete type as `worker_type`
to keep the slot field concrete. If you omit `worker_type`, on-demand slots use
`Any` for maximum flexibility.

Worker names are `Symbol` by default. If you need another name type, pass
`name_type`, but symbols are preferred because they are compact and easy to use
as result keys.

`workerfinalizer` may select a finalizer function from the job. That function is
called as `finalizer(worker, slot, job, manager)`, or with fewer trailing
arguments if it accepts less. Return `nothing` to use the default finalizer for
that job.

By default `OnDemandWorkers()` destroys the job worker after `consume!` and
`release!`, using `destroyworker!` when the recipe defines it, then `close!`,
and otherwise the default worker close behavior. Pass
`destroy_after_finalize = false` to keep the finished worker in the slot until
the next job replaces it.

## Threaded Scheduling

`runthreaded!(manager, jobs)` uses `Dynamic()` scheduling by default.

```julia
runthreaded!(manager, jobs)
runthreaded!(manager, jobs, Static())
runthreaded!(manager, jobs, Greedy())
```

The schedule controls how Julia assigns job iterations to threads and how the
manager maps those iterations onto slots:

| Schedule | Slot mapping | Use when | Main cost |
| --- | --- | --- | --- |
| `Dynamic()` | Each iteration borrows a slot from a bounded channel. | Job runtimes may vary, or you want the default bounded scheduling behavior. | Channel traffic for every job. |
| `Static()` | Each Julia thread uses `slots(manager)[Threads.threadid()]`. | Jobs have similar cost and you want a stable thread-to-slot mapping. | Requires at least `Threads.maxthreadid()` slots and can leave work imbalanced. |
| `Greedy()` | Greedy Julia scheduling with the same bounded slot pool as `Dynamic()`. | Job costs are uneven enough that greedy scheduling improves balance. | Can lose on tiny jobs because scheduling overhead dominates. |

`Dynamic()` is the safest default for heterogeneous job streams. `Static()` is
often fastest for many equal CPU-bound jobs because it avoids the slot-pool
channel and each thread reuses the same slot. `Greedy()` is worth measuring for
long-tailed job costs, for example when a few simulations or samples take much
longer than the rest.

For local comparisons, run the threaded mode profiler from the repository root:

```bash
julia --project=. --threads=auto Profiling/manager/threaded_modes/compare_threaded_modes.jl
julia --project=. --threads=auto Profiling/manager/threaded_modes/actual_process_workloads.jl
```

The convenience form below is equivalent to `runthreaded!`:

```julia
run!(manager, jobs, Dynamic())
```

## Run Lifecycle

For each job, the manager uses this order:

1. Borrow a free slot.
2. Store the job in `slot.job`.
3. Call `prepare!(slot, job, manager)`.
4. Call `runarguments(slot, job, manager)`.
5. Start the process with the named tuple returned by `runarguments`. For
   `Process` workers, `lifetime`, `repeats`, and `repeat` are reserved launch
   controls; all other keys are passed as runtime `@input` values.
6. Wait for the process to finish. In threaded mode this means the inline
   process run has returned. In the polling mode this means `isdone` reported
   that the process is finished.
7. Call `finalize!(slot, job, manager)`, or `wait(slot.worker); close(slot.worker)`
   if no `finalize!` callback exists. This is the first hook after the process
   has finished and the last hook before result-reading callbacks run.
8. Call `afterrun!(slot, job, manager)`.
9. Call `consume!(slot, job, manager)`.
10. Call `release!(slot, job, manager)`.
11. Return the slot to the pool.

If a recipe defines `start!(slot, job, manager)`, that callback replaces steps 4
and 5. Use `start!` only when you want to take over process launch completely.

For `Process` workers, threaded mode runs the process inline inside the current
threaded iteration through `runprocessinline!`. The non-threaded manager run uses:

```julia
run(slot.worker)
wait(slot.worker)
close(slot.worker)
```

`close(worker)` stores the finished process context back on the worker when the
process returns a context. That makes `consume!` the right place to read final
context values.

If a job needs to affect both persistent context and loop-level runtime inputs,
use two different steps: prepare the context in `prepare!`, then pass runtime
inputs from `runarguments`.

<<<<<<< HEAD
## What `flush!` Is For

`flush!` is a manager-level callback that runs after completed worker runs are
available. Its job is to take data that has already been produced by workers and
merge it into one shared destination.

The key point is that `flush!` is not the place where one worker finishes. That
happens earlier, through `finalize!`, `afterrun!`, `consume!`, and `release!`.
`flush!` runs later, according to `flush_policy`, after one or more completed
runs are waiting to be flushed.

In practice, `flush!` is useful when workers accumulate local data that should
only be merged occasionally. Common examples are:

- combine per-worker gradients into one global gradient update,
- gather worker-local output batches into one manager-owned buffer,
- write many finished results to disk in one batch,
- clear worker-local accumulation buffers after their contents were merged.

### Exact Timing

The manager only calls `flush!` when at least one run has completed since the
previous flush.

- `FlushAtEnd()`: `flush!` runs once after the whole `run!(manager, jobs)` or
  `runthreaded!(manager, jobs)` call has finished.
- `FlushEvery(n; drain = true)`: `flush!` runs after every `n` completed runs.
  With `drain = true`, active slots are finalized before the flush. With
  `drain = false`, only already-finished slots contribute.
- `NoFlush()`: `flush!` is never called automatically.

So `flush!` is a batching point, not a per-job callback.

### `flush!` Versus `consume!`

Use `consume!` when you want to react to one finished worker immediately.

Use `flush!` when you want to merge or apply results from many finished workers
together.

That distinction matters in learning-style workloads:

- `consume!`: append one worker's scalar loss to a history array.
- `flush!`: sum gradients from all workers, apply one optimizer step, then zero
  worker-local gradient buffers.

### Example: Batch Gradient Update

```julia
recipe = (;
    initstate = config -> (;
        params = Ref(config.initial_params),
        lr = config.lr,
    ),

    flush! = manager -> begin
        total_grad = 0.0

        for slot in slots(manager)
            ctx = context(slot.worker)[MyAlgo]
            total_grad += ctx.grad[]
            ctx.grad[] = 0.0
        end

        manager.state.params[] -= manager.state.lr * total_grad
=======
## Running Custom Code On Worker Threads

Use threaded manager mode when setup work must run on the same Julia thread as
the process loop:

```julia
runthreaded!(manager, jobs)

# Equivalent convenience forms:
run!(manager, jobs, Dynamic())
run!(manager, jobs, Static())
run!(manager, jobs, Greedy())
```

In these modes, each job owns one slot for the duration of a threaded iteration.
For a `Process` worker and no custom `start!`, the code executed on that thread
is:

```julia
prepare!(manager.recipe, slot, job, manager)
kwargs = runarguments(manager.recipe, slot, job, manager)
runprocessinline!(slot.worker; kwargs...)
finalize!(manager.recipe, slot, job, manager)
afterrun!(manager.recipe, slot, job, manager)
consume!(manager.recipe, slot, job, manager)
release!(manager.recipe, slot, job, manager)
```

That makes `prepare!` the normal place for per-job thread-local setup before the
loop algorithm runs:

```julia
recipe = (;
    makeworker = (idx, manager) -> Process(MyAlgorithm; repeats = 1),
    prepare! = (slot, job, manager) -> begin
        # This runs on the same thread that will run the process loop when using
        # runthreaded! or run!(manager, jobs, Dynamic()/Static()/Greedy()).
        ctx = context(slot.worker)[MyAlgorithm]
        ctx.input[] = job.input
        ctx.thread_id[] = Threads.threadid()
        return nothing
    end,
    runarguments = (slot, job, manager) -> (; temperature = job.temperature),
    consume! = (slot, job, manager) -> push!(manager.state.outputs, job.id),
)
```

Use `runarguments` when the pre-run code should compute loop-level runtime
inputs immediately before launch. For `Process` workers, return `lifetime`,
`repeats`, or `repeat` from the same named tuple to control the per-job process
lifetime:

```julia
recipe = (;
    makeworker = (idx, manager) -> Process(MyAlgorithm; repeats = 1),
    prepare! = (slot, job, manager) -> begin
        context(slot.worker)[MyAlgorithm].input[] = job.input
        return nothing
    end,
    runarguments = (slot, job, manager) -> begin
        # Also runs on the worker thread in threaded manager mode.
        (;
            temperature = job.temperature,
            thread_id = Threads.threadid(),
            repeats = job.repeats,
        )
>>>>>>> d6b3a8504846923aa37cef15958a4fded63b4258
    end,
)
```

<<<<<<< HEAD
Each worker accumulates its own `ctx.grad[]` locally. `flush!` reads those local
buffers, combines them, updates the shared manager parameters once, and clears
the local buffers.

### Why `flush!` Exists

Without `flush!`, every worker completion would have to update shared state
immediately. That often forces extra synchronization or makes the logic harder
to reason about.

`flush!` gives you one explicit place to say: "all completed worker results up
to this point may now be merged into shared manager state."
=======
Use `lifetime` when the job already has a `Lifetime` object, for example
`Repeat(10)`, `Until(...)`, or `AtLeastAtMost(...)`:

```julia
runarguments = (slot, job, manager) -> (;
    temperature = job.temperature,
    lifetime = job.lifetime,
)
```

Do not return both `lifetime` and `repeats` for one job. These keys are consumed
by the manager launch path and are not passed to runtime `@input` validation for
`Process` workers.

Use `start!` only when the launch itself must be custom. Defining `start!`
replaces the default `runarguments` + `runprocessinline!` launch, so call
`runprocessinline!` yourself if you still want inline `Process` execution:

```julia
recipe = (;
    makeworker = (idx, manager) -> Process(MyAlgorithm; repeats = 1),
    prepare! = (slot, job, manager) -> begin
        context(slot.worker)[MyAlgorithm].input[] = job.input
        return nothing
    end,
    start! = (slot, job, manager) -> begin
        # Custom thread-local setup immediately before the loop starts.
        job.before_run!(Threads.threadid())
        return runprocessinline!(
            slot.worker;
            temperature = job.temperature,
        )
    end,
    isdone = (slot, manager) -> true,
    finalize! = (slot, job, manager) -> nothing,
)
```

In the polling manager path, `prepare!` and `runarguments` run on the manager
task, and `run(slot.worker; kwargs...)` starts the process asynchronously. Use
threaded manager mode when same-thread setup is part of the contract.
>>>>>>> d6b3a8504846923aa37cef15958a4fded63b4258

## What `finalize!` Is For

`finalize!` is for making a just-finished process ready to be inspected. It is
called after the process run has completed, before `afterrun!`, `consume!`, and
`release!`.

For normal `Process` workers, the default finalization is:

```julia
wait(slot.worker)
close(slot.worker)
```

That default is important because `close` stores the returned context back on
the process. After that, `consume!` can read `context(slot.worker)` and see the
finished values.

Define `finalize!` yourself when the default wait-and-close behavior is not the
right finish step. Common cases are:

- a custom worker type needs a different method to retrieve the final result,
- the worker returns a value that should be placed in `slot.result`,
- close should be delayed because the worker is owned by another object,
- extra validation must run before `consume!` reads the finished context.

Do not use `finalize!` for normal result accumulation. Put that in `consume!`,
which runs immediately after finalization.

## Chunked Inline Workers

Use `InlineChunkWorker` when each slot should keep an `InlineProcess` on one
task for several examples. `runchunks!` groups examples into vector chunks, and
each chunk is dispatched as one manager job. Inside that chunk task, the recipe
loads one example at a time into the inline process context and runs the inline
process synchronously.

```julia
worker = InlineChunkWorker(InlineProcess(MyAlgo; repeats = 1))

recipe = (;
    resetexample! = (process, example, slot, manager) -> begin
        ctx = context(process)[MyAlgo]
        empty!(ctx.buffer)
    end,

    loadexample! = (process, example, slot, manager) -> begin
        ctx = context(process)[MyAlgo]
        ctx.x[] = example.x
    end,

    afterexample! = (process, example, result, slot, manager) -> begin
        ctx = context(process)[MyAlgo]
        push!(manager.state.outputs, ctx.y[])
    end,
)

manager = ProcessManager(
    recipe;
    workers = (worker,),
    job_type = Vector{eltype(dataset)},
)

runchunks!(manager, dataset; chunksize = 128)
```

The default `runchunks!` form uses the polling manager path and starts one task
per chunk. To run chunks through the threaded manager schedules instead, pass a
schedule:

```julia
runchunks!(manager, dataset, Dynamic(); chunksize = 128)
runchunks!(manager, dataset, Static(); chunksize = 128)
runchunks!(manager, dataset, Greedy(); chunksize = 128)
```

In scheduled chunk mode, `beforechunk!`, `resetexample!`, `loadexample!`,
`afterexample!`, and `afterchunk!` run on the threaded iteration that owns the
slot, and no extra task is spawned for the chunk.

`resetexample!` is optional. If it is omitted, context state carries from one
example to the next inside a chunk. `loadexample!` is required. `beforechunk!`
and `afterchunk!` are optional hooks around the whole chunk.

## Recipe Callbacks

A recipe can be a named tuple or an object with methods for these callbacks.
Callbacks can accept fewer trailing arguments if they do not need all of them.
The recipe object is stored as a concrete field of the manager, so anonymous
functions in a named tuple are part of the manager type.

- `initstate(config, manager)`: build `manager.state` from user configuration.
- `makeworker(idx, manager)`: create process `idx` when `workers` is not passed.
- `makeworker(idx, manager, job)`: create the worker for one job when
  `worker_lifecycle = OnDemandWorkers()`.
- `workername(idx, manager)`: name reusable workers at manager construction.
- `workername(idx, manager, job)`: name an on-demand worker from job data.
- `makecontext(idx, manager, template)`: for manager-owned `Process` workers,
  build the context for slot `idx` from the template process.
- `prepare!(slot, job, manager)`: write one job into a process before it starts.
  This is the usual place to mutate context, call `reinitworker!`, or call
  `partialinitworker!`. In threaded manager mode, this callback runs on the same
  thread that will run the process loop.
- `runarguments(slot, job, manager)`: return a named tuple of runtime keyword
  arguments for the implicit `run(...)` call. This callback may also run
  arbitrary manager-side code before launch. For example,
  `(; temperature = job.temperature)` becomes
  `run(slot.worker; temperature = job.temperature)`. In threaded manager mode,
  this callback runs on the same thread that will run the process loop. For
  `Process` workers, `lifetime`, `repeats`, and `repeat` are reserved launch
  controls and are removed before runtime `@input` validation.
- `start!(slot, job, manager)`: advanced custom process start. If this callback
  exists, it replaces `runarguments` and the implicit `run(...)` call. For
  `Process` workers in threaded manager mode, call `runprocessinline!` inside
  `start!` when custom launch code should still run the process inline.
- `isdone(slot, manager)`: custom completion check. Defaults to
  `isdone(worker)` for `Process` workers.
- `finalize!(slot, job, manager)`: custom finish step called after the process
  has completed and before `afterrun!` and `consume!`. Defaults to
  `wait(worker); close(worker)` for `Process` workers.
- `workerfinalizer(slot, job, manager)`: select a finalizer function for the
  current job. Ignored when `finalize!` is present.
- `afterrun!(slot, job, manager)`: optional hook after finalization.
- `consume!(slot, job, manager)`: read a finished process and accumulate output.
- `release!(slot, job, manager)`: clear local state after `consume!`.
- `flush!(manager)`: move slot-local buffers into manager state or another
  destination.
- `close!(slot, manager)`: custom process close.
- `destroyworker!(slot, job, manager)`: cleanup hook for
  `OnDemandWorkers(destroy_after_finalize = true)`. If this is missing, the
  manager falls back to `close!`.
- `onerror!(slot, err, manager)`: custom error handling.
- `beforechunk!(process, chunk, slot, manager)`: optional chunk setup for
  `InlineChunkWorker`.
- `resetexample!(process, example, slot, manager)`: optional per-example reset
  for `InlineChunkWorker`.
- `loadexample!(process, example, slot, manager)`: required per-example context
  load for `InlineChunkWorker`.
- `afterexample!(process, example, result, slot, manager)`: optional
  per-example consume hook for `InlineChunkWorker`.
- `afterchunk!(process, chunk, slot, manager)`: optional chunk cleanup for
  `InlineChunkWorker`.

`config` is construction input. `state` is runtime data owned by the manager.
Prefer putting shared runtime buffers, counters, parameters, optimizer state,
and logs in `initstate` instead of keeping them as unrelated external mutable
objects.

## Context Reuse

The manager reuses the same process objects. Context reuse depends on what your
recipe does in `prepare!`.

Use direct mutation when only a few fields change. After mutating the context,
call `resetworker!(slot)` if the next run should restart the process counters
from the beginning:

```julia
prepare! = (slot, job, manager) -> begin
    ctx = context(slot.worker)[MyAlgo]
    ctx.x[] = job.x
    empty!(ctx.buffer)
    resetworker!(slot)
end
```

`resetworker!` does not reset context values. For a `Process`, it sets
`loopidx = 1`, `tickidx = 1`, `paused = false`, `shouldrun = true`,
`starttime = nothing`, and `endtime = nothing`, then calls
`reset!(getalgo(slot.worker))`. It does not replace `runtime_context`,
`task`, or `lastresult`. Arrays, refs, and other values already stored in
`context(slot.worker)` remain unchanged. In the example above, `ctx.x[]` keeps
the value assigned from `job.x`, and `ctx.buffer` is cleared only because the
recipe calls `empty!`.

Use `reinitworker!` when the job should replace the whole process context
through the normal init path:

```julia
prepare! = (slot, job, manager) -> reinitworker!(
    slot,
    Init(MyAlgo; x = job.x),
)
```

`reinitworker!` runs `init(getalgo(slot.worker), ...)` and installs the new
context on the process. Use it when previous context contents should not carry
into the next job.

Use `partialinitworker!` when only one algorithm or state target should be
rebuilt through its `init` method:

```julia
prepare! = (slot, job, manager) -> partialinitworker!(
    slot,
    Init(MyAlgo; x = job.x),
)
```

`partialinitworker!` starts from the current context and replaces only the
targeted subcontext values. Other subcontexts keep their current values.

Use `runarguments` for loop-level runtime `@input` values:

```julia
runarguments = (slot, job, manager) -> (; temperature = job.temperature)
```

You can use both for the same job. The manager calls `prepare!` first, then
`runarguments`, then `run(slot.worker; temperature = job.temperature)`.

Direct mutation is usually faster. `reinitworker!` and `partialinitworker!` are
useful when the context shape, inputs, or initialized state must be rebuilt. Do
not create a new `Process` inside a callback unless you intentionally want to
give up context reuse.

## Result Collection

Use `consume!` to read one finished process. This hook runs after the process
has finished and been finalized.

If processes are reused, avoid storing mutable context objects for later unless
you know they will not be overwritten. Store copied values instead:

```julia
consume! = (slot, job, manager) -> begin
    ctx = context(slot.worker)[MyAlgo]
    push!(manager.state.outputs, (; value = ctx.value[], loss = ctx.loss[]))
end
```

## Flush Policies

`flush_policy` controls when `flush!(manager)` is called.

- `FlushAtEnd()` is the default. It runs all jobs first, drains all active
  slots, then calls `flush!` once.
- `NoFlush()` never calls `flush!` automatically. Use this when `consume!`
  handles all result collection.
- `FlushEvery(n; drain = true)` calls `flush!` after every `n` completed
  process runs. When `drain = true`, all active slots are finalized before
  flushing. When `drain = false`, only already-finished slots are flushed.

`flush!` runs after finished values are available, so it can merge slot-local
buffers without making those buffers thread-safe.

## Manual Non-Threaded Scheduling

The manager also has a lower-level, polling-based interface:

```julia
dispatch!(manager, job)
poll!(manager)
wait(manager)
drain!(manager)
```

Use this only when you need manual control over dispatch and polling. For normal
threaded `Process` runs, prefer `runthreaded!`.

`wait(manager)` waits until all currently active workers finish. `drain!(manager)`
also applies the final flush policy after all active workers have finished.

`poll_interval = 0.0` means the manager yields while waiting. A positive
`poll_interval` sleeps for that many seconds between checks when all slots are
busy.

## Type Hints

For lower overhead, pass concrete slot field types when they are known:

```julia
template_worker = Process(MyAlgo; repeats = 1)

manager = ProcessManager(
    recipe;
    nworkers = 4,
    job_type = eltype(jobs),
    result_type = typeof(template_worker),
)
```

Usually `job_type = eltype(jobs)` is the most important one. If a callback
stores a result in `slot.result`, set `result_type` to that result type.

The manager stores its slots in a tuple. This keeps the slot container type
fixed after construction and leaves room for processes with different concrete
types. `workers(manager)` returns the same fixed-shape tuple of process objects.

```@docs
StatefulAlgorithms.ProcessManager
StatefulAlgorithms.WorkerSlot
StatefulAlgorithms.FlushPolicy
StatefulAlgorithms.FlushAtEnd
StatefulAlgorithms.NoFlush
StatefulAlgorithms.FlushEvery
StatefulAlgorithms.WorkerLifecycle
StatefulAlgorithms.ReuseWorker
StatefulAlgorithms.OnDemandWorkers
StatefulAlgorithms.ThreadsType
StatefulAlgorithms.Static
StatefulAlgorithms.Dynamic
StatefulAlgorithms.Greedy
StatefulAlgorithms.slots
StatefulAlgorithms.workers
StatefulAlgorithms.copyworker
StatefulAlgorithms.InlineChunkWorker
StatefulAlgorithms.runchunks!
StatefulAlgorithms.prepare!
StatefulAlgorithms.runarguments
StatefulAlgorithms.start!
StatefulAlgorithms.beforechunk!
StatefulAlgorithms.resetexample!
StatefulAlgorithms.loadexample!
StatefulAlgorithms.afterexample!
StatefulAlgorithms.afterchunk!
StatefulAlgorithms.dispatch!
StatefulAlgorithms.poll!
StatefulAlgorithms.drain!
StatefulAlgorithms.run!
StatefulAlgorithms.runthreaded!
StatefulAlgorithms.resetworker!
StatefulAlgorithms.reinitworker!
StatefulAlgorithms.partialinitworker!
```

## Manager-Owned Process Example

```julia
template = Process(
    MyAlgo,
    Init(MyAlgo; value = Ref(0), local_buffer = Int[]),
    Override(MyAlgo; delta = 3);
    repeats = 20,
)

recipe = (;
    initstate = config -> (;
        output = Int[],
        scale = config.scale,
    ),

    makeworker = (idx, manager) -> copyprocess(template; context = deepcopy(context(template))),

    prepare! = (slot, job, manager) -> begin
        ctx = context(slot.worker)[MyAlgo]
        ctx.value[] = job.value * manager.state.scale
        resetworker!(slot)
    end,

    flush! = manager -> begin
        for slot in slots(manager)
            ctx = context(slot.worker)[MyAlgo]
            append!(manager.state.output, ctx.local_buffer)
            empty!(ctx.local_buffer)
        end
    end,
)

manager = ProcessManager(
    recipe;
    nworkers = 4,
    config = (; scale = 2),
    flush_policy = FlushAtEnd(),
    job_type = eltype(jobs),
    result_type = typeof(template),
)

runthreaded!(manager, jobs)
manager.state.output
```

The manager calls `flush!` automatically according to `flush_policy`; normal
code does not call it directly.

## Existing Process Example

```julia
workers = [Process(MyAlgo; repeats = 1) for _ in 1:4]

recipe = (;
    prepare! = (slot, job, manager) -> begin
        ctx = context(slot.worker)[MyAlgo]
        ctx.value[] = job.value
        resetworker!(slot)
    end,

    consume! = (slot, job, manager) -> begin
        ctx = context(slot.worker)[MyAlgo]
        push!(manager.state.outputs, ctx.value[])
    end,

    initstate = config -> (; outputs = Int[]),
)

manager = ProcessManager(
    recipe;
    workers,
    config = (;),
    flush_policy = NoFlush(),
    job_type = eltype(jobs),
    result_type = eltype(workers),
)

runthreaded!(manager, jobs)
manager.state.outputs
```

Use existing processes only when they must be owned or prepared outside the
manager. Otherwise prefer the manager-owned form with `makeworker`.
