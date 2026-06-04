# ProcessManager is a small lifecycle scheduler for reusable workers.
#
# It deliberately does not know what a "batch", "gradient", or "sample" is.
# Users pass jobs from any iterable collection, and attach behavior to manager
# phases such as prepare, start, finalize, consume, release, and flush. The
# recipe object is stored concretely in `ProcessManager{Recipe,...}`, so named
# tuples of closures keep their closure types available to inference.

export ProcessManager, WorkerSlot
export WorkerInitMode, CopyFirstWorker, MakeEachWorker
export WorkerLifecycle, ReuseWorker
export FlushPolicy, FlushAtEnd, NoFlush, FlushEvery
export dispatch!, poll!, drain!, run!, resetworker!, reinitworker!, partialinitworker!, slots, workers, copyworker, runprocessinline!

"""
Worker construction mode used when a `ProcessManager` owns its workers.
"""
abstract type WorkerInitMode end

"""
    CopyFirstWorker()

Build slot 1 with `makeworker`, then build later slots through `copyworker`.
This is the default historical manager behavior.
"""
struct CopyFirstWorker <: WorkerInitMode end

"""
    MakeEachWorker()

Call `makeworker(idx, manager)` independently for every owned worker slot.
Use this when workers should be uniquely initialized instead of copied or
deep-copied from slot 1.
"""
struct MakeEachWorker <: WorkerInitMode end

"""
Worker lifecycle policy controlling whether slots keep one reusable worker or
replace the worker for every job.
"""
abstract type WorkerLifecycle end

"""
    ReuseWorker()

Keep the historical manager behavior: each slot owns one reusable worker, and
jobs update that worker through recipe callbacks such as `prepare!`.
"""
struct ReuseWorker <: WorkerLifecycle end

"""
Policy trait controlling when a `ProcessManager` invokes a recipe `flush!` callback.
"""
abstract type FlushPolicy end

"""
    FlushAtEnd()

Flush worker-local buffers once, after all dispatched work has drained.
"""
struct FlushAtEnd <: FlushPolicy end

"""
    NoFlush()

Never invoke the recipe `flush!` callback automatically.
"""
struct NoFlush <: FlushPolicy end

"""
    FlushEvery(n; drain = true)

Invoke the recipe `flush!` callback after every `n` completed worker runs.
When `drain` is true, all active workers are finalized before flushing.
"""
struct FlushEvery <: FlushPolicy
    n::Int
    drain::Bool
    function FlushEvery(n::Integer; drain::Bool = true)
        n > 0 || throw(ArgumentError("`n` must be positive."))
        return new(Int(n), drain)
    end
end

"""
    _normalize_flush_policy(policy)

Validate and return a concrete `FlushPolicy` value.
"""
_normalize_flush_policy(policy::FlushPolicy) = policy
_normalize_flush_policy(policy) = throw(ArgumentError("`flush_policy` must be a FlushPolicy, got $(typeof(policy))."))

"""
    _normalize_worker_lifecycle(lifecycle)

Validate and return a concrete `WorkerLifecycle` value.
"""
_normalize_worker_lifecycle(lifecycle::L) where {L<:WorkerLifecycle} = lifecycle
_normalize_worker_lifecycle(lifecycle) = throw(ArgumentError("`worker_lifecycle` must be a WorkerLifecycle, got $(typeof(lifecycle))."))

"""
    WorkerSlot

Transparent manager-owned slot around a reusable worker.

The `worker` field is intentionally public so recipes can inspect and mutate the
underlying worker context directly.
"""
mutable struct WorkerSlot{W, Job, Scratch, Result, Err, Name}
    idx::Int                         # Stable slot number inside the manager.
    name::Name                       # User-facing worker name for logs/results.
    worker::W                        # Reusable worker object owned or wrapped by the slot.
    job::Union{Nothing, Job}          # Job currently assigned to this slot.
    scratch::Union{Nothing, Scratch}  # Optional user scratch storage for recipes.
    result::Union{Nothing, Result}    # Result returned by finalize! or worker finalization.
    error::Union{Nothing, Err}        # Last error seen while this slot was active.
    active::Bool                      # True between successful start and finish.
    runs::Int                         # Number of completed jobs on this slot.
end

"""
    WorkerSlot(idx, worker; name = Symbol(:worker_, idx), scratch = nothing)

Create an untyped slot around `worker`. The main `ProcessManager` constructor
usually creates slots with concrete job/result/error field types instead.
"""
WorkerSlot(idx::Integer, worker; name = Symbol(:worker_, idx), scratch = nothing) =
    WorkerSlot{typeof(worker), Any, Any, Any, Any, typeof(name)}(Int(idx), name, worker, nothing, scratch, nothing, nothing, false, 0)

"""
    context(slot::WorkerSlot)

Return the current context of `slot.worker`.

For a `Process` slot, this is the same object returned by
`context(slot.worker)`. Mutating fields in this context changes the data the
next managed run will see.
"""
context(slot::WorkerSlot) = context(slot.worker)

"""
    resetworker!(slot)

Reset `slot.worker` by calling `reset!(slot.worker)` and return `slot`.

For a `Process`, this performs these exact mutations:

- `slot.worker.loopidx = 1`
- `slot.worker.tickidx = 1`
- `slot.worker.paused = false`
- `slot.worker.shouldrun = true`
- `slot.worker.starttime = nothing`
- `slot.worker.endtime = nothing`
- `reset!(getalgo(slot.worker))`

It does not change `slot.worker.runtime_context`, `slot.worker.task`, or
`slot.worker.lastresult`. It also does not rebuild or clear values stored in the
process context. Context fields, arrays, buffers, and refs stay exactly as they
were.

Call this from `prepare!` after you have loaded the next job into an existing
context and want the next run to start from the first repeat/step again. Use
`reinitworker!` or `partialinitworker!` when context values should be rebuilt
through `init`.
"""
resetworker!(slot::WorkerSlot) = (reset!(slot.worker); slot)

"""
    reinitworker!(slot, inputs_overrides...; kwargs...)

Replace the whole context of `slot.worker` by running the normal process init
pipeline, then return `slot`.

This is different from `resetworker!`: it rebuilds context values by calling
`init(getalgo(slot.worker), inputs_overrides...; lifetime = lifetime(slot.worker))`
and then committing the resulting persistent context back onto the worker. Use
it from `prepare!` when a job needs freshly initialized context state instead
of reusing the previous context object.
"""
function reinitworker!(slot::WorkerSlot{<:Process}, inputs_overrides...; kwargs...)
    commit_context!(slot.worker, context(init(getalgo(slot.worker), inputs_overrides...; lifetime = lifetime(slot.worker))))
    return slot
end

"""
    partialinitworker!(slot, inputs_overrides...)

Reinitialize only the context targets named by `inputs_overrides`, then return
`slot`.

This keeps the existing process context as the starting point and runs
`partialinit` for the affected algorithm or state entries. Use it when one part
of the context should be rebuilt through its `init` method while the rest of the
context should keep its current values. Concretely, it builds a lifecycle-wrapped
algorithm from the current process context, runs `partialinit(algo, inputs_overrides...)`,
and assigns the returned context back to `slot.worker`.
"""
function partialinitworker!(slot::WorkerSlot{<:Process}, inputs_overrides...)
    algo = _with_lifecycle(
        getalgo(slot.worker),
        context(slot.worker),
        getstoredinits(getalgo(slot.worker)),
        getstoredoverrides(getalgo(slot.worker)),
    )
    commit_context!(slot.worker, context(partialinit(algo, inputs_overrides...)))
    return slot
end

"""
    _manager_launch_lifetime(worker, kwargs)

Extract a per-run process lifetime from manager launch keyword arguments.
`lifetime`, `repeats`, and `repeat` are launch controls, not runtime inputs.
"""
function _manager_launch_lifetime(worker::P, kwargs::K) where {P<:Process, K<:NamedTuple}
    lifetime_value = get(kwargs, :lifetime, nothing)
    repeats_value = get(kwargs, :repeats, nothing)
    repeat_value = get(kwargs, :repeat, nothing)
    has_lifetime = !isnothing(lifetime_value)
    has_repeats = !isnothing(repeats_value)
    has_repeat = !isnothing(repeat_value)
    has_repeats && has_repeat && throw(ArgumentError("Pass either `repeats` or `repeat`, not both."))
    has_lifetime && (has_repeats || has_repeat) && throw(ArgumentError("Pass either `lifetime` or `repeats`/`repeat`, not both."))

    raw_lifetime = if has_lifetime
        lifetime_value
    elseif has_repeats
        repeats_value
    elseif has_repeat
        repeat_value
    else
        nothing
    end
    return isnothing(raw_lifetime) ? nothing : normalize_process_lifetime(getalgo(worker), raw_lifetime)
end

"""
    _manager_process_launch_args(worker, kwargs)

Split manager launch arguments into `(lifetime, runtime_kwargs)` for a `Process`
worker. Runtime keyword arguments are passed to the loop as `@input` values.
"""
function _manager_process_launch_args(worker::P, kwargs::K) where {P<:Process, K<:NamedTuple}
    lifetime = _manager_launch_lifetime(worker, kwargs)
    runtime_kwargs = deletekeys(kwargs, :lifetime, :repeats, :repeat)
    return lifetime, runtime_kwargs
end

"""
    runprocessinline!(worker; lifetime = nothing, repeats = nothing, repeat = nothing, kwargs...)

Run a `Process` worker synchronously in the current task and store the resulting
runtime context back on the worker. This avoids per-job `Task` allocation for
threaded manager jobs.
"""
function runprocessinline!(worker::P; lifetime = nothing, repeats = nothing, repeat = nothing, kwargs...) where {P<:Process}
    @assert isidle(worker) "Process is already in use"
    @atomic worker.shouldrun = true
    @atomic worker.paused = false
    worker.lastresult = nothing

    launch_kwargs = (; lifetime, repeats, repeat)
    launch_lifetime = _manager_launch_lifetime(worker, launch_kwargs)
    if !isnothing(launch_lifetime)
        worker.lifetime = launch_lifetime
    end

    # Build the same runtime context as the asynchronous Process path, but call
    # the loop directly so no scheduler task is created for short manager jobs.
    algo = getalgo(worker)
    inputs = _validate_runtime_inputs(algo, (; kwargs...))
    base_context = _has_typed_runtime_context(worker) ? _typed_runtime_context(worker) : context(worker)
    lt = StatefulAlgorithms.lifetime(worker)
    result = loop(worker, algo, base_context, lt, inputs, Resuming{false}())

    worker.lastresult = result
    worker.task = nothing
    worker.loopidx = 1
    @atomic worker.shouldrun = false
    return worker
end

"""
    ProcessManager(recipe; nworkers = Threads.nthreads(), workers = nothing,
                   config = nothing, state = nothing, flush_policy = FlushAtEnd(),
                   worker_lifecycle = ReuseWorker(),
                   worker_init = CopyFirstWorker(),
                   worker_init_data = nothing,
                   worker_type = nothing,
                   name_type = Symbol,
                   throw = true, poll_interval = 0.0,
                   job_type = Any, scratch_type = Any,
                   result_type = Any, error_type = Any)

Flexible worker orchestrator.

Recipes may be named tuples containing callbacks, or concrete objects that
overload the callback functions below. The default worker protocol supports
`Process` workers.

For each job, the manager moves through fixed lifecycle steps: assign a free
slot, call `prepare!`, call `runarguments`, implicitly run the worker, poll for
completion, finalize, consume, release, and eventually flush. Attach behavior to
these steps with recipe callbacks. For example, `prepare!` may mutate or
reinitialize a worker context, and `runarguments` may return keyword arguments
for `run(slot.worker; kwargs...)`.

When `workers` is omitted, the recipe must define `makeworker`. The manager calls
`makeworker` once to create a template worker, then copies that template for the
remaining slots. The default `Process` copy reuses the template task description
and deep-copies the runtime context. Recipes can define
`makecontext(idx, manager, template)` to build a separate `Process` context for
each slot while keeping the template task description, or
`copyworker(template, idx, manager)` when the whole worker copy must be custom. When
`workers` is passed, the manager wraps those existing workers in slots and does
not create new worker contexts.

Set `worker_init = MakeEachWorker()` to call `makeworker(idx, manager)` for every
owned slot instead of copying slot 1. This avoids the manager's deepcopy-based
default `Process` copy path entirely. Pass `worker_init_data = data` to provide
one value per worker; callbacks may accept it as `makeworker(idx, manager, data)`.

Use `worker_lifecycle = OnDemandWorkers()` when workers should be constructed
from job data instead of upfront. That mode lives in `OnDemandWorkers.jl` and
uses `makeworker(idx, manager, job)` for each dispatched job. Pass
`worker_type` when the job may choose among different concrete worker types.

Slots have a public `name` field for logs and result lookup. Missing
`workername` callbacks use names such as `:worker_1`. Pass `name_type` if names
should use a type other than `Symbol`.

The `job_type`, `scratch_type`, `result_type`, and `error_type` keywords let
latency-sensitive code make worker slot fields concrete. Leaving them as `Any`
keeps the manager fully flexible.
"""
mutable struct ProcessManager{Recipe, W, Config, State, Policy <: FlushPolicy, Lifecycle <: WorkerLifecycle}
    recipe::Recipe              # Concrete callback container or recipe object.
    slots::W                    # Tuple of mutable WorkerSlot objects.
    config::Config              # Construction-time configuration retained for users.
    state::State                # Manager-owned runtime state built by initstate.
    flush_policy::Policy        # Policy deciding when recipe flush! is called.
    worker_lifecycle::Lifecycle # Policy deciding whether workers are reused or replaced per job.
    throw::Bool                 # Whether slot errors are rethrown immediately.
    poll_interval::Float64      # Sleep interval used while waiting for slots.
    completions::Int            # Total completed worker runs.
    completions_since_flush::Int # Completed runs since the last flush.
    dispatched::Int             # Total jobs successfully started.
    active_count::Int           # Number of slots currently marked active.
    free_hint::Int              # Rotating slot index where the next free search starts.
    errors::Vector{Any}         # Errors recorded from slot lifecycle hooks.
    closed::Bool                # True after Base.close(manager).
    owns_workers::Bool          # True when workers were constructed by manager.
end

"""
    ProcessManager(recipe, slots, config, state, flush_policy, throw,
                   poll_interval, completions, completions_since_flush,
                   dispatched, errors, closed, owns_workers)

Compatibility constructor for the pre-active-count positional manager shape.
It derives active-slot bookkeeping from the supplied slot states.
"""
function ProcessManager(
    recipe::Recipe,
    slots::W,
    config::Config,
    state::State,
    flush_policy::Policy,
    throw::Bool,
    poll_interval::Float64,
    completions::Integer,
    completions_since_flush::Integer,
    dispatched::Integer,
    errors::Vector{Any},
    closed::Bool,
    owns_workers::Bool,
) where {Recipe, W, Config, State, Policy<:FlushPolicy}
    active_count = count(slot -> slot.active, slots)
    free_idx = findfirst(slot -> !slot.active, slots)
    free_hint = isnothing(free_idx) ? 1 : Int(free_idx)
    return ProcessManager{Recipe, W, Config, State, Policy, ReuseWorker}(
        recipe,
        slots,
        config,
        state,
        flush_policy,
        ReuseWorker(),
        throw,
        poll_interval,
        Int(completions),
        Int(completions_since_flush),
        Int(dispatched),
        active_count,
        free_hint,
        errors,
        closed,
        owns_workers,
    )
end

"""
    ProcessManager(recipe, slots, config, state, flush_policy, throw,
                   poll_interval, completions, completions_since_flush,
                   dispatched, active_count, free_hint, errors, closed,
                   owns_workers)

Compatibility constructor for the reusable-worker manager shape that predates
`worker_lifecycle`.
"""
function ProcessManager(
    recipe::Recipe,
    slots::W,
    config::Config,
    state::State,
    flush_policy::Policy,
    throw::Bool,
    poll_interval::Float64,
    completions::Integer,
    completions_since_flush::Integer,
    dispatched::Integer,
    active_count::Integer,
    free_hint::Integer,
    errors::Vector{Any},
    closed::Bool,
    owns_workers::Bool,
) where {Recipe, W, Config, State, Policy<:FlushPolicy}
    return ProcessManager{Recipe, W, Config, State, Policy, ReuseWorker}(
        recipe,
        slots,
        config,
        state,
        flush_policy,
        ReuseWorker(),
        throw,
        poll_interval,
        Int(completions),
        Int(completions_since_flush),
        Int(dispatched),
        Int(active_count),
        Int(free_hint),
        errors,
        closed,
        owns_workers,
    )
end

const _PROCESSMANAGER_PRECOMPILE_LOCK = ReentrantLock()
const _PROCESSMANAGER_PRECOMPILE_TYPES = Set{Any}()

"""
    _slot_job_type(slot_type_or_slot)

Return the declared job type stored in a `WorkerSlot`.
"""
_slot_job_type(::WorkerSlot{W, Job}) where {W, Job} = Job

"""
    _first_slot_type(slots)

Return the concrete type of the first slot in a non-empty slot tuple.
"""
function _first_slot_type(slots::Tuple)
    return typeof(first(slots))
end

"""
    _precompile_processmanager!(ManagerType, SlotType, JobType)

Best-effort precompile of the manager methods that are normally hit when a
manager starts processing jobs.
"""
function _precompile_processmanager!(::Type{M}, ::Type{Slot}, ::Type{Job}) where {M<:ProcessManager, Slot<:WorkerSlot, Job}
    _try_precompile(dispatch!, (M, Job))
    _try_precompile(poll!, (M,))
    _try_precompile(wait, (M,))
    _try_precompile(drain!, (M,))
    _try_precompile(run!, (M, Vector{Job}))
    _try_precompile(_wait_active_slots!, (M,))
    _try_precompile(_wait_for_free_slot!, (M,))
    _try_precompile(_finish_done_slots!, (M,))
    _try_precompile(_finish_slot!, (M, Slot))
    _try_precompile(_start_slot!, (M, Slot, Job))
    _try_precompile(_run_kwargs, (M, Slot, Job))
    _try_precompile(_slot_isdone, (M, Slot))
    return nothing
end

"""
    schedule_processmanager_precompile!(manager)

Schedule best-effort manager precompilation for this concrete manager/slot/job
shape. This runs in the background outside package image generation.
"""
function schedule_processmanager_precompile!(manager::ProcessManager)
    _is_generating_package_output() && return nothing
    isempty(slots(manager)) && return nothing

    manager_type = typeof(manager)
    slot_type = _first_slot_type(slots(manager))
    job_type = _slot_job_type(first(slots(manager)))
    signature = (manager_type, slot_type, job_type)

    should_schedule = lock(_PROCESSMANAGER_PRECOMPILE_LOCK) do
        if !(signature in _PROCESSMANAGER_PRECOMPILE_TYPES)
            push!(_PROCESSMANAGER_PRECOMPILE_TYPES, signature)
            return true
        end
        return false
    end
    should_schedule && Threads.@spawn _precompile_processmanager!(manager_type, slot_type, job_type)
    return nothing
end

"""
    _slot_container(workers, worker_names, Job, Scratch, Result, Err,
                    worker_type = nothing, name_type = Any)

Wrap worker values in a typed tuple of mutable `WorkerSlot`s.
"""
function _slot_container(workers, worker_names, ::Type{Job}, ::Type{Scratch}, ::Type{Result}, ::Type{Err}, worker_type = nothing, ::Type{Name} = Any) where {Job, Scratch, Result, Err, Name}
    return Tuple(
        WorkerSlot{_slot_worker_type(worker, worker_type), Job, Scratch, Result, Err, _slot_name_type(worker_names[Int(idx)], Name)}(
            Int(idx),
            worker_names[Int(idx)],
            worker,
            nothing,
            nothing,
            nothing,
            nothing,
            false,
            0,
        )
        for (idx, worker) in enumerate(workers)
    )
end

"""
    _slot_name_type(name, Name)

Return the name field type for one slot and validate explicit name type
requests.
"""
function _slot_name_type(name, ::Type{Name}) where {Name}
    name isa Name || throw(ArgumentError("`name_type = $Name` cannot store worker name of type $(typeof(name))."))
    return Name
end

"""
    _set_slot_name!(slot, name)

Assign a new worker name to `slot`, validating the slot's name field type before
mutation.
"""
function _set_slot_name!(slot::WorkerSlot{W, Job, Scratch, Result, Err, Name}, name) where {W, Job, Scratch, Result, Err, Name}
    name isa Name || throw(ArgumentError("Worker name $(repr(name)) has type $(typeof(name)), which cannot be stored in a slot typed for $Name."))
    slot.name = name
    return slot
end

"""
    _slot_worker_type(worker, worker_type)

Return the worker field type for one slot. The default keeps the exact worker
type; explicit `worker_type` values opt into a broader slot worker field.
"""
_slot_worker_type(worker, ::Nothing) = typeof(worker)

function _slot_worker_type(worker, ::Type{W}) where {W}
    worker isa W || throw(ArgumentError("`worker_type = $W` cannot store initial worker of type $(typeof(worker))."))
    return W
end

function _slot_worker_type(worker, worker_type)
    throw(ArgumentError("`worker_type` must be a type or `nothing`, got $(typeof(worker_type))."))
end

"""
    _manager_worker_values(recipe, nworkers, build_manager, worker_init,
                           worker_init_data, workers, lifecycle)

Return the initial worker values for the manager lifecycle. Reusable workers are
constructed upfront; other lifecycle modes may override this in their own file.
"""
function _manager_worker_values(recipe, nworkers::Integer, build_manager, worker_init::WIM, worker_init_data, workers, ::WorkerLifecycle) where {WIM<:WorkerInitMode}
    if isnothing(workers)
        return _owned_worker_values(recipe, nworkers, build_manager, worker_init, worker_init_data)
    end

    collected = collect(workers)
    isempty(collected) && throw(ArgumentError("`workers` must not be empty."))
    return Tuple(collected)
end

"""
    _manager_worker_names(recipe, nworkers, build_manager, workers, lifecycle)

Return the initial worker names for the manager lifecycle. Reusable workers are
named at construction; other lifecycle modes may override this in their own
file.
"""
function _manager_worker_names(recipe, nworkers::Integer, build_manager, workers, ::WorkerLifecycle)
    return ntuple(Int(nworkers)) do idx
        workername(recipe, idx, build_manager)
    end
end

"""
    _manager_slot_worker_type(worker_type, lifecycle)

Normalize the requested slot worker type for a manager lifecycle.
"""
_manager_slot_worker_type(worker_type, ::WorkerLifecycle) = worker_type

"""
    _manager_slot_name_type(name_type, lifecycle)

Normalize the requested slot name type for a manager lifecycle.
"""
_manager_slot_name_type(::Type{Name}, ::WorkerLifecycle) where {Name} = Name
_manager_slot_name_type(name_type, ::WorkerLifecycle) =
    throw(ArgumentError("`name_type` must be a type, got $(typeof(name_type))."))

"""
    _has_recipe_callback(recipe, Val(name))

Return whether `recipe` defines a non-`nothing` callback field named `name`.
"""
_has_recipe_callback(recipe, name::Val{Name}) where {Name} = !_is_no_recipe_callback(_recipe_field(recipe, name))

"""
    _worker_context(recipe, idx, manager, template)

Call an optional recipe `makecontext` callback for manager-owned `Process`
workers.
"""
function _worker_context(recipe, idx, manager, template)
    return _call_optional_recipe_field(recipe, Val(:makecontext), idx, manager, template)
end

"""
    _process_with_context(template, idx, prepared_context)

Build a worker from a template and a slot-specific context. The default
implementation supports `Process` templates.
"""
function _process_with_context(template::Process, idx::Integer, prepared_context)
    return Process(getalgo(template); context = prepared_context, lifetime = lifetime(template), timeout = template.timeout)
end

"""
    _process_with_context(template, idx, prepared_context)

Error path for non-`Process` templates that try to use `makecontext` without a
custom `copyworker` implementation.
"""
function _process_with_context(template, idx::Integer, prepared_context)
    throw(ArgumentError("Recipe callback `makecontext` is only supported by default for `Process` workers. Define `copyworker` to customize non-Process worker construction."))
end

"""
    _validate_worker_init_data(worker_init_data, nworkers)

Validate optional per-worker construction data and return it unchanged.
"""
function _validate_worker_init_data(worker_init_data::Data, nworkers::Integer) where {Data}
    isnothing(worker_init_data) && return nothing
    length(worker_init_data) == Int(nworkers) || throw(ArgumentError("`worker_init_data` must have one entry per worker."))
    return worker_init_data
end

"""
    _has_worker_init_data(worker_init_data)

Return whether manager-owned worker construction should pass per-slot data into
worker-construction callbacks.
"""
_has_worker_init_data(worker_init_data::Data) where {Data} = !isnothing(worker_init_data)

"""
    _worker_init_value(worker_init_data, idx)

Return the per-worker construction data for slot `idx`.
"""
_worker_init_value(worker_init_data::Data, idx::Integer) where {Data} = worker_init_data[Int(idx)]

"""
    _makeworker(recipe, idx, manager, worker_init_data)

Call `makeworker`, optionally passing the per-worker construction value as a
third callback argument.
"""
function _makeworker(recipe::Recipe, idx::Integer, manager::M, worker_init_data::Data) where {Recipe, M<:ProcessManager, Data}
    if _has_worker_init_data(worker_init_data)
        return makeworker(recipe, idx, manager, _worker_init_value(worker_init_data, idx))
    end
    return makeworker(recipe, idx, manager)
end

"""
    _worker_context(recipe, idx, manager, template, worker_init_data)

Call `makecontext`, optionally passing the per-worker construction value as a
fourth callback argument.
"""
function _worker_context(recipe::Recipe, idx::Integer, manager::M, template, worker_init_data::Data) where {Recipe, M<:ProcessManager, Data}
    if _has_worker_init_data(worker_init_data)
        return _call_optional_recipe_field(recipe, Val(:makecontext), idx, manager, template, _worker_init_value(worker_init_data, idx))
    end
    return _worker_context(recipe, idx, manager, template)
end

"""
    _copyworker(recipe, template, idx, manager, worker_init_data)

Call `copyworker`, optionally passing the per-worker construction value as a
fourth callback argument.
"""
function _copyworker(recipe::Recipe, template, idx::Integer, manager::M, worker_init_data::Data) where {Recipe, M<:ProcessManager, Data}
    if _has_worker_init_data(worker_init_data)
        return copyworker(recipe, template, idx, manager, _worker_init_value(worker_init_data, idx))
    end
    return copyworker(recipe, template, idx, manager)
end

"""
    _owned_worker_values(recipe, nworkers, build_manager)

Create the worker tuple for a manager that owns its workers. The first worker is
made by `makeworker`; later workers are either slot-specific contexts or copied
from the template.
"""
function _owned_worker_values(recipe, nworkers::Integer, build_manager, ::CopyFirstWorker, worker_init_data)
    template = _makeworker(recipe, 1, build_manager, worker_init_data)

    if _has_recipe_callback(recipe, Val(:makecontext))
        return ntuple(Int(nworkers)) do idx
            prepared_context = _worker_context(recipe, idx, build_manager, template, worker_init_data)
            _process_with_context(template, idx, prepared_context)
        end
    end

    return ntuple(Int(nworkers)) do idx
        idx == 1 ? template : _copyworker(recipe, template, idx, build_manager, worker_init_data)
    end
end

"""
    _owned_worker_values(recipe, nworkers, build_manager, ::MakeEachWorker)

Create each manager-owned worker by calling `makeworker` for that slot index.
This path does not copy or deepcopy a template worker.
"""
function _owned_worker_values(recipe, nworkers::Integer, build_manager, ::MakeEachWorker, worker_init_data)
    return ntuple(Int(nworkers)) do idx
        _makeworker(recipe, idx, build_manager, worker_init_data)
    end
end

"""
    ProcessManager(recipe; ...)

Construct a manager and its worker slots. Recipes are stored concretely, so a
named tuple of anonymous functions becomes part of the manager type.
"""
function ProcessManager(recipe; nworkers::Integer = Threads.nthreads(), workers = nothing, config = nothing, state = nothing, flush_policy = FlushAtEnd(), worker_lifecycle = ReuseWorker(), worker_init::WIM = CopyFirstWorker(), worker_init_data = nothing, worker_type = nothing, name_type::Type{Name} = Symbol, throw::Bool = true, poll_interval::Real = 0.0, job_type::Type{Job} = Any, scratch_type::Type{Scratch} = Any, result_type::Type{Result} = Any, error_type::Type{Err} = Any) where {Job, Scratch, Result, Err, Name, WIM<:WorkerInitMode}
    nworkers > 0 || throw(ArgumentError("`nworkers` must be positive."))
    prepared_worker_init_data = _validate_worker_init_data(worker_init_data, nworkers)
    normalized_policy = _normalize_flush_policy(flush_policy)
    normalized_lifecycle = _normalize_worker_lifecycle(worker_lifecycle)
    prepared_state = if isnothing(state)
        initstate(recipe, config, nothing)
    else
        state
    end
    build_manager = ProcessManager(recipe, (), config, prepared_state, normalized_policy, normalized_lifecycle, throw, Float64(poll_interval), 0, 0, 0, 0, 1, Any[], false, isnothing(workers))

    worker_values = _manager_worker_values(
        recipe,
        nworkers,
        build_manager,
        worker_init,
        prepared_worker_init_data,
        workers,
        normalized_lifecycle,
    )
    worker_names = _manager_worker_names(recipe, length(worker_values), build_manager, workers, normalized_lifecycle)

    slot_worker_type = _manager_slot_worker_type(worker_type, normalized_lifecycle)
    slot_name_type = _manager_slot_name_type(name_type, normalized_lifecycle)
    slot_values = _slot_container(worker_values, worker_names, job_type, scratch_type, result_type, error_type, slot_worker_type, slot_name_type)
    manager = ProcessManager(recipe, slot_values, config, prepared_state, normalized_policy, normalized_lifecycle, throw, Float64(poll_interval), 0, 0, 0, 0, 1, Any[], false, isnothing(workers))
    schedule_processmanager_precompile!(manager)
    return manager
end

"""
    slots(manager)

Return the manager's mutable worker slots.
"""
slots(manager::ProcessManager) = manager.slots

"""
    _slot_worker(slot)

Return the worker value stored by a slot. This is the mapping function behind
`workers(manager)`.
"""
_slot_worker(slot::WorkerSlot) = slot.worker

"""
    workers(manager)

Return the workers stored in each manager slot.
"""
workers(manager::ProcessManager) = map(_slot_worker, manager.slots)

"""
Sentinel returned by optional recipe lookup when a callback is not defined.
"""
struct NoRecipeCallback end

"""
    _is_no_recipe_callback(value)

Return whether `value` is the missing-callback sentinel.
"""
_is_no_recipe_callback(::NoRecipeCallback) = true
_is_no_recipe_callback(_) = false

"""
    _recipe_field(recipe, Val(name))

Fetch a callback field from a named-tuple-like recipe. Missing or `nothing`
fields are represented by `NoRecipeCallback()`.
"""
@inline function _recipe_field(recipe, ::Val{name}) where {name}
    hasfield(typeof(recipe), name) || return NoRecipeCallback()
    callback = getfield(recipe, name)
    return isnothing(callback) ? NoRecipeCallback() : callback
end

"""
    _call_with_supported_arity(f, args...)

Call `f` with the longest supported prefix of `args`. This lets callbacks ignore
trailing lifecycle arguments without forcing users to write unused parameters.
"""
@inline _call_with_supported_arity(f) = f()

"""
    _valname(Val(name))

Return the symbol stored in a `Val`, used only for clearer callback errors.
"""
_valname(::Val{name}) where {name} = name

@inline function _call_with_supported_arity(f, a)
    applicable(f, a) && return f(a)
    applicable(f) && return f()
    throw(MethodError(f, (a,)))
end

@inline function _call_with_supported_arity(f, a, b)
    applicable(f, a, b) && return f(a, b)
    applicable(f, a) && return f(a)
    applicable(f) && return f()
    throw(MethodError(f, (a, b)))
end

@inline function _call_with_supported_arity(f, a, b, c)
    applicable(f, a, b, c) && return f(a, b, c)
    applicable(f, a, b) && return f(a, b)
    applicable(f, a) && return f(a)
    applicable(f) && return f()
    throw(MethodError(f, (a, b, c)))
end

@inline function _call_with_supported_arity(f, a, b, c, d)
    applicable(f, a, b, c, d) && return f(a, b, c, d)
    applicable(f, a, b, c) && return f(a, b, c)
    applicable(f, a, b) && return f(a, b)
    applicable(f, a) && return f(a)
    applicable(f) && return f()
    throw(MethodError(f, (a, b, c, d)))
end

@inline function _call_with_supported_arity(f, a, b, c, d, e)
    applicable(f, a, b, c, d, e) && return f(a, b, c, d, e)
    applicable(f, a, b, c, d) && return f(a, b, c, d)
    applicable(f, a, b, c) && return f(a, b, c)
    applicable(f, a, b) && return f(a, b)
    applicable(f, a) && return f(a)
    applicable(f) && return f()
    throw(MethodError(f, (a, b, c, d, e)))
end

function _call_with_supported_arity(f, args...)
    throw(MethodError(f, args))
end

"""
    _call_recipe_field(recipe, Val(name), args...)

Call a required recipe callback and throw a clear error when it is absent.
"""
function _call_recipe_field(recipe, name::Val{Name}, args...) where {Name}
    callback = _recipe_field(recipe, name)
    _is_no_recipe_callback(callback) && throw(ArgumentError("Recipe does not define callback `$(_valname(name))`."))
    return _call_with_supported_arity(callback, args...)
end

"""
    _call_optional_recipe_field(recipe, Val(name), args...)

Call an optional recipe callback. Missing callbacks return
`NoRecipeCallback()`, which callers use to select default behavior.
"""
function _call_optional_recipe_field(recipe, name::Val{Name}, args...) where {Name}
    callback = _recipe_field(recipe, name)
    _is_no_recipe_callback(callback) && return NoRecipeCallback()
    return _call_with_supported_arity(callback, args...)
end

"""
    makeworker(recipe, idx, manager)

Required callback used when the manager owns workers and must construct the
template worker.
"""
makeworker(recipe, idx, manager) = _call_recipe_field(recipe, Val(:makeworker), idx, manager)
makeworker(recipe, idx, manager, initdata) = _call_recipe_field(recipe, Val(:makeworker), idx, manager, initdata)

"""
    _default_copyworker(template, idx, manager)

Default worker-copy rule. `Process` workers keep the same algorithm/lifetime and
deep-copy context; other worker objects are deep-copied directly.
"""
function _default_copyworker(template::Process, idx, manager)
    return Process(getalgo(template); context = deepcopy(context(template)), lifetime = lifetime(template), timeout = template.timeout)
end
_default_copyworker(template, idx, manager) = deepcopy(template)

"""
    copyworker(recipe, template, idx, manager)

Copy a manager-owned template worker for slot `idx`, using recipe `copyworker`
when provided.
"""
function copyworker(recipe, template, idx, manager)
    result = _call_optional_recipe_field(recipe, Val(:copyworker), template, idx, manager)
    return _is_no_recipe_callback(result) ? _default_copyworker(template, idx, manager) : result
end

function copyworker(recipe, template, idx, manager, initdata)
    result = _call_optional_recipe_field(recipe, Val(:copyworker), template, idx, manager, initdata)
    return _is_no_recipe_callback(result) ? _default_copyworker(template, idx, manager) : result
end

"""
    initstate(recipe, config, manager)

Build the object stored in `manager.state`.

`config` is the construction-time input passed to `ProcessManager(...; config = ...)`.
Use `initstate` to turn that configuration into long-lived manager-side runtime
data such as shared buffers, global parameters, counters, logs, or optimizer
state.

This state object is separate from worker contexts:

- `manager.state` is shared manager-owned data.
- `context(slot.worker)` is the per-worker process context.

If the recipe does not define `initstate`, the manager stores `nothing` in
`manager.state`.
"""
function initstate(recipe, config, manager)
    result = _call_optional_recipe_field(recipe, Val(:initstate), config, manager)
    return _is_no_recipe_callback(result) ? nothing : result
end

"""
    workername(recipe, idx, manager)
    workername(recipe, idx, manager, job)

Optional callback for naming workers. Missing callbacks use the slot index.
On-demand workers usually define the four-argument form so the job can provide
the experiment or worker name.
"""
function workername(recipe, idx, manager)
    result = _call_optional_recipe_field(recipe, Val(:workername), idx, manager)
    return _is_no_recipe_callback(result) ? Symbol(:worker_, idx) : result
end

function workername(recipe, idx, manager, job)
    result = _call_optional_recipe_field(recipe, Val(:workername), idx, manager, job)
    return _is_no_recipe_callback(result) ? Symbol(:worker_, idx) : result
end

"""
    prepare!(recipe, slot, job, manager)

Optional dispatch-step callback. This is where jobs usually mutate or
reinitialize worker-local context before `runarguments` and the implicit worker
run.
"""
prepare!(recipe, slot, job, manager) = _call_optional_recipe_field(recipe, Val(:prepare!), slot, job, manager)

"""
    runarguments(recipe, slot, job, manager)

Optional dispatch-step callback that returns runtime keyword arguments for the
implicit worker launch. The callback may also run arbitrary manager-side code
before launch. Return a `NamedTuple` for `run(slot.worker; kwargs...)`, or return
`nothing` for no runtime keyword arguments.
"""
runarguments(recipe, slot, job, manager) = _call_optional_recipe_field(recipe, Val(:runarguments), slot, job, manager)

"""
    start!(recipe, slot, job, manager)

Advanced dispatch-step callback that replaces the implicit launch completely.
Use this for custom workers or nonstandard scheduling. Missing callbacks use
`runarguments` and then call `run(slot.worker; kwargs...)`.
"""
start!(recipe, slot, job, manager) = _call_optional_recipe_field(recipe, Val(:start!), slot, job, manager)

"""
    isdone(recipe, slot, manager)

Optional poll-step callback returning whether a slot's worker has finished.
"""
isdone(recipe, slot, manager) = _call_optional_recipe_field(recipe, Val(:isdone), slot, manager)

"""
    finalize!(recipe, slot, job, manager)

Optional finish-step callback for a completed slot.

The manager calls this after the worker has finished and before `afterrun!`,
`consume!`, and `release!`. Missing callbacks wait for and close `Process`
workers, which stores the finished context back on the process before result
collection.
"""
finalize!(recipe, slot, job, manager) = _call_optional_recipe_field(recipe, Val(:finalize!), slot, job, manager)

"""
    workerfinalizer(recipe, slot, job, manager)

Optional finish-step callback that selects a finalizer function for this job's
worker. The selected function is called with `(worker, slot, job, manager)`, or
with any shorter supported prefix. Return `nothing` to use the default worker
finalization for that job.
"""
workerfinalizer(recipe, slot, job, manager) = _call_optional_recipe_field(recipe, Val(:workerfinalizer), slot, job, manager)

"""
    afterrun!(recipe, slot, job, manager)

Optional hook called after worker finalization and before `consume!`.
"""
afterrun!(recipe, slot, job, manager) = _call_optional_recipe_field(recipe, Val(:afterrun!), slot, job, manager)

"""
    consume!(recipe, slot, job, manager)

Optional finish-step callback for reading a finished worker and accumulating
results.
"""
consume!(recipe, slot, job, manager) = _call_optional_recipe_field(recipe, Val(:consume!), slot, job, manager)

"""
    release!(recipe, slot, job, manager)

Optional finish-step callback for clearing slot-local state after `consume!`.
"""
release!(recipe, slot, job, manager) = _call_optional_recipe_field(recipe, Val(:release!), slot, job, manager)

"""
    flush!(recipe, manager)

Optional manager-level callback controlled by the manager's `FlushPolicy`.

The manager calls this only after one or more worker runs have completed. It is
the usual place to merge per-worker buffers into shared manager state, apply one
batched parameter update, write accumulated results to an external destination,
or clear worker-local accumulation buffers for the next batch of jobs.

`flush!` is not called per job. Its timing depends on `flush_policy`:

- `FlushAtEnd()`: once after the run finishes.
- `FlushEvery(n; drain = true)`: after every `n` completed runs, with optional
  draining of active slots first.
- `NoFlush()`: never called automatically.
"""
flush!(recipe, manager) = _call_optional_recipe_field(recipe, Val(:flush!), manager)

"""
    close!(recipe, slot, manager)

Optional callback used when closing a manager or cleaning up a failed slot.
"""
close!(recipe, slot, manager) = _call_optional_recipe_field(recipe, Val(:close!), slot, manager)

"""
    onerror!(recipe, slot, err, manager)

Optional callback called when a lifecycle step throws.
"""
onerror!(recipe, slot, err, manager) = _call_optional_recipe_field(recipe, Val(:onerror!), slot, err, manager)

"""
    _start_worker!(worker, kwargs)

Default worker launch step. `Process` workers are launched with
`run(worker; kwargs...)`; custom worker types can either support the same call
shape or provide recipe `start!`.
"""
function _start_worker!(worker::Process, kwargs::NamedTuple)
    lifetime, runtime_kwargs = _manager_process_launch_args(worker, kwargs)
    run(worker, lifetime; runtime_kwargs...)
    return worker
end

"""
    _start_worker!(worker, kwargs)

Generic default worker launch step for non-`Process` workers.
"""
function _start_worker!(worker, kwargs::NamedTuple)
    run(worker; kwargs...)
    return worker
end

"""
    _start_worker!(worker)

Launch a worker with no runtime keyword arguments.
"""
_start_worker!(worker) = _start_worker!(worker, (;))

"""
    _assign_job_worker!(manager, slot, job)

Install a lifecycle-specific worker for `job`. The reusable-worker mode keeps
the current slot worker.
"""
function _assign_job_worker!(manager::M, slot::S, job) where {M<:ProcessManager, S<:WorkerSlot}
    return _assign_job_worker!(manager, slot, job, manager.worker_lifecycle)
end

"""
    _assign_job_worker!(manager, slot, job, ::ReuseWorker)

Keep the current reusable slot worker.
"""
function _assign_job_worker!(manager::M, slot::S, job, ::ReuseWorker) where {M<:ProcessManager, S<:WorkerSlot}
    return slot
end

"""
    _run_kwargs(manager, slot, job)

Run recipe `runarguments` and normalize its return value to keyword arguments for
the implicit worker launch.
"""
function _run_kwargs(manager::ProcessManager, slot::WorkerSlot, job)
    result = runarguments(manager.recipe, slot, job, manager)
    (_is_no_recipe_callback(result) || isnothing(result)) && return (;)
    result isa NamedTuple && return result
    throw(ArgumentError("Recipe callback `runarguments` must return a NamedTuple of keyword arguments or `nothing`, got $(typeof(result))."))
end

"""
    _worker_isdone(worker)

Default completion check for a worker. `Process` workers use `isdone(worker)`;
other worker types should provide recipe `isdone` unless they support the same
operation.
"""
_worker_isdone(worker::Process) = isdone(worker)

"""
    _finalize_worker!(worker)

Default finish step for a `Process`: wait for completion, close it, and leave the
finished context stored on the process.
"""
function _finalize_worker!(worker::Process)
    wait(worker)
    close(worker)
    return worker
end

"""
    _finalize_worker_with(finalizer, worker, slot, job, manager)

Call a job-selected worker finalizer with the richest supported lifecycle
argument list.
"""
function _finalize_worker_with(finalizer, worker, slot::S, job, manager::M) where {S<:WorkerSlot, M<:ProcessManager}
    return _call_with_supported_arity(finalizer, worker, slot, job, manager)
end

"""
    _close_worker!(worker)

Default worker cleanup used when a manager closes a slot without a recipe
`close!` callback.
"""
function _close_worker!(worker::Process)
    close(worker)
    return worker
end

"""
    _destroy_finished_job_worker!(manager, slot, job)

Run lifecycle-specific cleanup after result collection.
"""
function _destroy_finished_job_worker!(manager::M, slot::S, job) where {M<:ProcessManager, S<:WorkerSlot}
    return _destroy_finished_job_worker!(manager, slot, job, manager.worker_lifecycle)
end

"""
    _destroy_finished_job_worker!(manager, slot, job, ::ReuseWorker)

Leave reusable workers alive after a job finishes.
"""
function _destroy_finished_job_worker!(manager::M, slot::S, job, ::ReuseWorker) where {M<:ProcessManager, S<:WorkerSlot}
    return slot
end

"""
    _start_slot!(manager, slot, job)

Start one assigned slot. Recipe `start!` is an advanced full override; otherwise
the manager runs `runarguments` and launches the worker with the returned keyword
arguments.
"""
function _start_slot!(manager::ProcessManager, slot::WorkerSlot, job)
    result = start!(manager.recipe, slot, job, manager)
    _is_no_recipe_callback(result) || return result
    return _start_worker!(slot.worker, _run_kwargs(manager, slot, job))
end

"""
    _slot_isdone(manager, slot)

Return whether an active slot has completed, using recipe `isdone` when present
and the worker default otherwise.
"""
function _slot_isdone(manager::ProcessManager, slot::WorkerSlot)
    result = isdone(manager.recipe, slot, manager)
    return _is_no_recipe_callback(result) ? _worker_isdone(slot.worker) : Bool(result)
end

"""
    _finalize_slot_worker!(manager, slot, job)

Finalize the worker for a completed slot, using recipe `finalize!` when present
and the worker default otherwise.
"""
function _finalize_slot_worker!(manager::ProcessManager, slot::WorkerSlot, job)
    result = finalize!(manager.recipe, slot, job, manager)
    _is_no_recipe_callback(result) || return result

    finalizer = workerfinalizer(manager.recipe, slot, job, manager)
    (_is_no_recipe_callback(finalizer) || isnothing(finalizer)) && return _finalize_worker!(slot.worker)
    return _finalize_worker_with(finalizer, slot.worker, slot, job, manager)
end

"""
    _next_slot_index(manager, idx)

Return the following slot index, wrapping back to the first slot. The manager
uses this to rotate free-slot searches instead of starting every search at
slot 1.
"""
@inline function _next_slot_index(manager::M, idx::Integer) where {M<:ProcessManager}
    slot_count = length(manager.slots)
    return idx >= slot_count ? 1 : Int(idx) + 1
end

"""
    _mark_slot_active!(manager, slot)

Record that `slot` has entered the active lifecycle and advance the free-slot
search hint past it.
"""
@inline function _mark_slot_active!(manager::M, slot::S) where {M<:ProcessManager, S<:WorkerSlot}
    slot.active = true
    manager.active_count += 1
    manager.free_hint = _next_slot_index(manager, slot.idx)
    return slot
end

"""
    _mark_slot_free!(manager, slot)

Record that `slot` has left the active lifecycle and make it the preferred
starting point for the next free-slot search.
"""
@inline function _mark_slot_free!(manager::M, slot::S) where {M<:ProcessManager, S<:WorkerSlot}
    if slot.active
        slot.active = false
        manager.active_count -= 1
        manager.free_hint = slot.idx
    end
    return slot
end

"""
    _safe_close_slot!(manager, slot)

Close a slot during manager cleanup or error recovery, recording close errors
instead of replacing the original lifecycle error.
"""
function _safe_close_slot!(manager::ProcessManager, slot::WorkerSlot)
    isnothing(slot.worker) && return slot
    try
        result = close!(manager.recipe, slot, manager)
        _is_no_recipe_callback(result) && _close_worker!(slot.worker)
    catch err
        push!(manager.errors, err)
    end
    return slot
end

"""
    _handle_slot_error!(manager, slot, err)

Record a lifecycle error, run recipe `onerror!`, and rethrow according to
`manager.throw`.
"""
function _handle_slot_error!(manager::ProcessManager, slot::WorkerSlot, err)
    slot.error = err
    push!(manager.errors, err)
    try
        onerror!(manager.recipe, slot, err, manager)
    catch hook_err
        push!(manager.errors, hook_err)
        manager.throw && throw(hook_err)
    end
    manager.throw && throw(err)
    return slot
end

"""
    _finish_slot!(manager, slot)

Complete one active slot: finalize the worker, run post-run hooks, collect
results, release slot state, and update completion counters.
"""
function _finish_slot!(manager::ProcessManager, slot::WorkerSlot)
    slot.active || return slot
    job = something(slot.job)
    try
        slot.result = _finalize_slot_worker!(manager, slot, job)
        afterrun!(manager.recipe, slot, job, manager)
        consume!(manager.recipe, slot, job, manager)
        release!(manager.recipe, slot, job, manager)
        _destroy_finished_job_worker!(manager, slot, job)
        slot.runs += 1
        manager.completions += 1
        manager.completions_since_flush += 1
    catch err
        _safe_close_slot!(manager, slot)
        _handle_slot_error!(manager, slot, err)
    finally
        _mark_slot_free!(manager, slot)
        slot.job = nothing
    end
    return slot
end

"""
    _finish_done_slots!(manager)

Poll all active slots once and finish every slot whose worker is done. Returns
the number of slots finished during this pass.
"""
function _finish_done_slots!(manager::ProcessManager)
    finished = 0
    for slot in manager.slots
        if slot.active && _slot_isdone(manager, slot)
            _finish_slot!(manager, slot)
            finished += 1
        end
    end
    return finished
end

"""
    _drain_active!(manager)

Finalize every active slot immediately. This is used before a draining flush.
"""
function _drain_active!(manager::ProcessManager)
    for slot in manager.slots
        slot.active && _finish_slot!(manager, slot)
    end
    return manager
end

"""
    _flush!(manager)

Invoke recipe `flush!` when there are completed runs waiting to be flushed, then
reset the flush counter.
"""
function _flush!(manager::ProcessManager)
    manager.completions_since_flush == 0 && return manager
    flush!(manager.recipe, manager)
    manager.completions_since_flush = 0
    return manager
end

"""
    _apply_flush_policy!(manager, ::NoFlush; final = false)

Apply the no-op flush policy.
"""
_apply_flush_policy!(manager::ProcessManager, ::NoFlush; final::Bool = false) = manager

"""
    _apply_flush_policy!(manager, ::FlushAtEnd; final = false)

Flush only during the final drain pass.
"""
function _apply_flush_policy!(manager::ProcessManager, ::FlushAtEnd; final::Bool = false)
    final && _flush!(manager)
    return manager
end

"""
    _apply_flush_policy!(manager, policy::FlushEvery; final = false)

Flush after the configured number of completions, optionally draining active
workers first.
"""
function _apply_flush_policy!(manager::ProcessManager, policy::FlushEvery; final::Bool = false)
    if manager.completions_since_flush >= policy.n || (final && manager.completions_since_flush > 0)
        policy.drain && _drain_active!(manager)
        _flush!(manager)
    end
    return manager
end

"""
    _next_free_slot(manager)

Return the index of the first inactive slot, or `nothing` when all slots are
busy.
"""
function _next_free_slot(manager::ProcessManager)
    manager.active_count >= length(manager.slots) && return nothing

    # Start from the last known free position and wrap once through the slots.
    idx = manager.free_hint
    for _ in eachindex(manager.slots)
        manager.slots[idx].active || return idx
        idx = _next_slot_index(manager, idx)
    end
    return nothing
end

"""
    _has_active_slots(manager)

Return whether any slot currently has an assigned running job.
"""
function _has_active_slots(manager::ProcessManager)
    return manager.active_count > 0
end

"""
    poll!(manager)

Finalize completed workers, make their slots reusable, and apply the configured
flush policy if it is due.
"""
function poll!(manager::ProcessManager)
    manager.closed && throw(ArgumentError("Cannot poll a closed ProcessManager."))
    _finish_done_slots!(manager)
    _apply_flush_policy!(manager, manager.flush_policy; final = false)
    return manager
end

"""
    _wait_for_free_slot!(manager)

Poll until a reusable slot is available, yielding or sleeping according to
`poll_interval` while all workers are busy.
"""
function _wait_for_free_slot!(manager::ProcessManager)
    while true
        free_idx = _next_free_slot(manager)
        isnothing(free_idx) || return manager.slots[free_idx]
        poll!(manager)
        if manager.active_count >= length(manager.slots)
            manager.poll_interval > 0 ? sleep(manager.poll_interval) : yield()
        end
    end
end

"""
    dispatch!(manager, job)

Schedule `job` on the next available worker slot, waiting for a slot to become
free when all workers are active.

The dispatch order is fixed: assign `slot.job`, clear old result/error state,
let the worker lifecycle prepare the slot, call recipe `prepare!`, call recipe
`runarguments`, implicitly run the worker, then mark the slot active. Recipe
`start!` replaces the `runarguments` and implicit run steps when present.
"""
function dispatch!(manager::ProcessManager, job)
    manager.closed && throw(ArgumentError("Cannot dispatch to a closed ProcessManager."))
    slot = _wait_for_free_slot!(manager)
    slot.job = job
    slot.result = nothing
    slot.error = nothing
    try
        _assign_job_worker!(manager, slot, job)
        prepare!(manager.recipe, slot, job, manager)
        _start_slot!(manager, slot, job)
        _mark_slot_active!(manager, slot)
        manager.dispatched += 1
    catch err
        _mark_slot_free!(manager, slot)
        slot.job = nothing
        _handle_slot_error!(manager, slot, err)
    end
    return slot
end

"""
    drain!(manager)

Wait for all active workers to finish, then apply the configured final flush
policy.
"""
function drain!(manager::ProcessManager)
    manager.closed && throw(ArgumentError("Cannot drain a closed ProcessManager."))
    _wait_active_slots!(manager)
    _apply_flush_policy!(manager, manager.flush_policy; final = true)
    return manager
end

"""
    _wait_active_slots!(manager)

Wait until all currently active manager slots have finished and been finalized.
This does not apply the manager's final flush policy.
"""
function _wait_active_slots!(manager::M) where {M<:ProcessManager}
    while _has_active_slots(manager)
        _finish_done_slots!(manager)

        # Avoid a busy loop while all remaining active slots are still running.
        if _has_active_slots(manager)
            manager.poll_interval > 0 ? sleep(manager.poll_interval) : yield()
        end
    end
    return manager
end

"""
    wait(manager)

Wait for all currently active manager workers to finish, without applying the
configured final flush policy. Use `drain!(manager)` when waiting should also
perform the final manager-level flush.
"""
function Base.wait(manager::M) where {M<:ProcessManager}
    manager.closed && throw(ArgumentError("Cannot wait on a closed ProcessManager."))
    return _wait_active_slots!(manager)
end

"""
    run!(manager, jobs)

Dispatch all `jobs`, keep workers busy according to the manager's slot limit,
and drain at the end.
"""
function run!(manager::ProcessManager, jobs)
    for job in jobs
        dispatch!(manager, job)
        poll!(manager)
    end
    drain!(manager)
    return manager
end

"""
    close(manager::ProcessManager)

Close active workers and, when the manager owns its workers, close all owned
workers. Existing workers passed with `workers = ...` are only closed if they are
active at close time.
"""
function Base.close(manager::ProcessManager)
    manager.closed && return true
    for slot in manager.slots
        (slot.active || manager.owns_workers) && _safe_close_slot!(manager, slot)
        _mark_slot_free!(manager, slot)
        slot.job = nothing
    end
    manager.active_count = 0
    manager.free_hint = 1
    manager.closed = true
    return true
end
