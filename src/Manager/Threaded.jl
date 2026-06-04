# Threaded manager runner for coarse-grained, reusable worker slots.
#
# This mode avoids the default manager's per-job task spawning and polling loop.
# The threaded loop runs over jobs, and each iteration borrows one reusable
# worker slot from a bounded pool.

export runthreaded!

"""
    _start_slot_inline!(manager, slot, job)

Run one assigned slot without creating a new task for default `Process` workers.
Recipe `start!` callbacks still override the default launch behavior.
"""
function _start_slot_inline!(manager::M, slot::S, job) where {M<:ProcessManager, S<:WorkerSlot}
    result = start!(manager.recipe, slot, job, manager)
    _is_no_recipe_callback(result) || return result

    kwargs = _run_kwargs(manager, slot, job)
    if slot.worker isa Process
        lifetime, runtime_kwargs = _manager_process_launch_args(slot.worker, kwargs)
        return runprocessinline!(slot.worker; lifetime = lifetime, runtime_kwargs...)
    end
    return _start_worker!(slot.worker, kwargs)
end

"""
    _safe_close_slot_threadlocal!(manager, slot, errors)

Close a slot while collecting close failures in thread-local error storage.
"""
function _safe_close_slot_threadlocal!(manager::M, slot::S, errors::Vector{Any}) where {M<:ProcessManager, S<:WorkerSlot}
    isnothing(slot.worker) && return slot
    try
        result = close!(manager.recipe, slot, manager)
        _is_no_recipe_callback(result) && _close_worker!(slot.worker)
    catch err
        push!(errors, err)
    end
    return slot
end

"""
    _handle_slot_error_threadlocal!(manager, slot, err, errors)

Record a slot lifecycle error without mutating the manager's shared error
vector from inside the threaded loop.
"""
function _handle_slot_error_threadlocal!(manager::M, slot::S, err, errors::Vector{Any}) where {M<:ProcessManager, S<:WorkerSlot}
    slot.error = err
    push!(errors, err)
    try
        onerror!(manager.recipe, slot, err, manager)
    catch hook_err
        push!(errors, hook_err)
    end
    return slot
end

"""
    _run_threaded_job!(manager, job, slot_idx, counts, dispatched, errors)

Run one job on one borrowed worker slot. The caller owns `slot_idx` until this
function returns, so slot fields and slot-local counters can be mutated without
additional locking.
"""
function _run_threaded_job!(
    manager::M,
    job::Job,
    slot_idx::I,
    counts::Vector{Int},
    dispatched::Vector{Int},
    errors_by_slot::Vector{Vector{Any}},
) where {M<:ProcessManager, Job, I<:Integer}
    slot = manager.slots[Int(slot_idx)]
    local_errors = errors_by_slot[Int(slot_idx)]
    slot.job = job
    slot.result = nothing
    slot.error = nothing
    slot.active = true

    try
        _assign_job_worker!(manager, slot, job)
        prepare!(manager.recipe, slot, job, manager)
        _start_slot_inline!(manager, slot, job)
        dispatched[Int(slot_idx)] += 1
        slot.result = _finalize_slot_worker!(manager, slot, job)
        afterrun!(manager.recipe, slot, job, manager)
        consume!(manager.recipe, slot, job, manager)
        release!(manager.recipe, slot, job, manager)
        _destroy_finished_job_worker!(manager, slot, job)
        slot.runs += 1
        counts[Int(slot_idx)] += 1
    catch err
        _safe_close_slot_threadlocal!(manager, slot, local_errors)
        _handle_slot_error_threadlocal!(manager, slot, err, local_errors)
    finally
        slot.active = false
        slot.job = nothing
    end
    return slot
end

"""
    _threaded_jobs(jobs)

Return an indexable job container for threaded slot slicing.
"""
_threaded_jobs(jobs::Union{AbstractArray, Tuple}) = jobs
_threaded_jobs(jobs) = collect(jobs)

"""
    _threaded_slot_pool(manager)

Create a blocking pool of reusable slot indices for dynamic threaded job
iterations.
"""
function _threaded_slot_pool(manager::M) where {M<:ProcessManager}
    slot_count = length(manager.slots)
    slot_pool = Channel{Int}(slot_count)
    for slot_idx in eachindex(manager.slots)
        Base.put!(slot_pool, Int(slot_idx))
    end
    return slot_pool
end

"""
    _run_threaded_borrowed_job!(manager, job, slot_pool, counts, dispatched, errors)

Borrow one slot, run one job, and return the slot to the pool.
"""
function _run_threaded_borrowed_job!(
    manager::M,
    job::Job,
    slot_pool::Channel{Int},
    counts::Vector{Int},
    dispatched::Vector{Int},
    errors_by_slot::Vector{Vector{Any}},
) where {M<:ProcessManager, Job}
    slot_idx = Base.take!(slot_pool)
    try
        _run_threaded_job!(manager, job, slot_idx, counts, dispatched, errors_by_slot)
    finally
        Base.put!(slot_pool, slot_idx)
    end
    return manager
end

"""
    _validate_static_thread_slots(manager)

Ensure thread-indexed static scheduling has one reusable slot per worker thread.
"""
function _validate_static_thread_slots(manager::M) where {M<:ProcessManager}
    required_slots = Threads.maxthreadid()
    length(manager.slots) >= required_slots || throw(ArgumentError("Static threaded manager mode requires at least Threads.maxthreadid() worker slots."))
    return manager
end

"""
    _run_threaded_jobs!(manager, jobs, schedule, counts, dispatched, errors)

Execute the job loop using the requested `Threads.@threads` schedule.
"""
function _run_threaded_jobs!(
    manager::M,
    jobs,
    schedule::S,
    counts::Vector{Int},
    dispatched::Vector{Int},
    errors_by_slot::Vector{Vector{Any}},
) where {M<:ProcessManager, S<:ThreadsType}
    if schedule isa Static
        _validate_static_thread_slots(manager)
        Threads.@threads :static for job in jobs
            _run_threaded_job!(manager, job, Threads.threadid(), counts, dispatched, errors_by_slot)
        end
    elseif schedule isa Greedy
        slot_pool = _threaded_slot_pool(manager)
        Threads.@threads :greedy for job in jobs
            _run_threaded_borrowed_job!(manager, job, slot_pool, counts, dispatched, errors_by_slot)
        end
    else
        slot_pool = _threaded_slot_pool(manager)
        Threads.@threads :dynamic for job in jobs
            _run_threaded_borrowed_job!(manager, job, slot_pool, counts, dispatched, errors_by_slot)
        end
    end
    return manager
end

"""
    _merge_threaded_errors!(manager, errors_by_slot)

Append slot-local threaded errors to the manager after the threaded barrier and
return the last new error, or `nothing` if this run did not record one.
"""
function _merge_threaded_errors!(manager::M, errors_by_slot::Vector{Vector{Any}}) where {M<:ProcessManager}
    last_error = nothing
    for slot_errors in errors_by_slot
        isempty(slot_errors) && continue
        append!(manager.errors, slot_errors)
        last_error = last(slot_errors)
    end
    return last_error
end

"""
    runthreaded!(manager, jobs, schedule = Dynamic())

Run all `jobs` through the manager with one `Threads.@threads` iteration per
job. Each iteration borrows one manager slot and runs default `Process` workers
inline instead of using per-job `Threads.@spawn` and polling.
"""
function runthreaded!(manager::M, jobs, schedule::S = Dynamic()) where {M<:ProcessManager, S<:ThreadsType}
    manager.closed && throw(ArgumentError("Cannot run a closed ProcessManager."))
    _has_active_slots(manager) && drain!(manager)

    prepared_jobs = _threaded_jobs(jobs)
    isempty(prepared_jobs) && return manager

    slot_count = length(manager.slots)
    counts = zeros(Int, slot_count)
    dispatched = zeros(Int, slot_count)
    errors_by_slot = [Any[] for _ in 1:slot_count]

    _run_threaded_jobs!(manager, prepared_jobs, schedule, counts, dispatched, errors_by_slot)

    # Merge slot-local accounting after the barrier to keep manager counters on
    # the caller task.
    completed_count = sum(counts)
    manager.dispatched += sum(dispatched)
    manager.completions += completed_count
    manager.completions_since_flush += completed_count
    manager.active_count = 0
    manager.free_hint = 1

    threaded_error = _merge_threaded_errors!(manager, errors_by_slot)
    manager.throw && !isnothing(threaded_error) && throw(threaded_error)

    _apply_flush_policy!(manager, manager.flush_policy; final = true)
    return manager
end

"""
    run!(manager, jobs, schedule)

Convenience form for `runthreaded!(manager, jobs, schedule)`.
"""
run!(manager::M, jobs, schedule::S) where {M<:ProcessManager, S<:ThreadsType} =
    runthreaded!(manager, jobs, schedule)
