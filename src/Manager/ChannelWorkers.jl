export ChannelWorkers, runchannel!

"""
    ChannelWorkers(; channel_size = nothing)
    ChannelWorkers(channel_size)

Manager run mode that starts one long-lived worker task per slot and has those
workers pull jobs from a channel until it closes. When `channel_size` is
`nothing`, the internal channel uses one slot per manager worker.
"""
struct ChannelWorkers{Size}
    channel_size::Size
end

ChannelWorkers(::Nothing) = ChannelWorkers{Nothing}(nothing)

function ChannelWorkers(channel_size::I) where {I<:Integer}
    channel_size >= 0 || throw(ArgumentError("`channel_size` must be non-negative."))
    return ChannelWorkers{I}(channel_size)
end

function ChannelWorkers(; channel_size = nothing)
    return ChannelWorkers(channel_size)
end

"""
    _channel_workers_size(mode, manager)

Return the bounded internal channel size requested by `mode`.
"""
function _channel_workers_size(mode::CW, manager::M) where {CW<:ChannelWorkers, M<:ProcessManager}
    size = getfield(mode, :channel_size)
    return isnothing(size) ? length(slots(manager)) : Int(size)
end

"""
    _manager_channel_job_type(manager)

Return the job type declared by the manager's slots for typed channel storage.
"""
function _manager_channel_job_type(manager::M) where {M<:ProcessManager}
    isempty(slots(manager)) && throw(ArgumentError("Channel manager mode requires at least one worker slot."))
    return _slot_job_type(first(slots(manager)))
end

"""
    _manager_job_channel(manager, channel_size)

Create the bounded job channel used by long-lived channel workers.
"""
function _manager_job_channel(manager::M, channel_size::I) where {M<:ProcessManager, I<:Integer}
    channel_size >= 0 || throw(ArgumentError("`channel_size` must be non-negative."))
    Job = _manager_channel_job_type(manager)
    return Channel{Job}(Int(channel_size))
end

"""
    _feed_channel_jobs!(jobs_channel, jobs)

Put every job from `jobs` into `jobs_channel` for worker-side consumption.
"""
function _feed_channel_jobs!(jobs_channel::Channel{Job}, jobs::Jobs) where {Job, Jobs}
    for job in jobs
        put!(jobs_channel, job)
    end
    return jobs_channel
end

"""
    _run_channel_worker!(manager, slot_idx, jobs, counts, dispatched, errors)

Keep one manager worker online, taking jobs from `jobs` until the channel closes.
Each job uses the same lifecycle callbacks as threaded manager mode, with
`Process` workers run inline on this worker task.
"""
function _run_channel_worker!(
    manager::M,
    slot_idx::I,
    jobs::Channel{Job},
    counts::Vector{Int},
    dispatched::Vector{Int},
    errors_by_slot::Vector{Vector{Any}},
) where {M<:ProcessManager, I<:Integer, Job}
    for job in jobs
        # Run the whole per-job lifecycle on this long-lived worker task, so
        # default Process workers do not allocate a separate task for each job.
        _run_threaded_job!(manager, job, slot_idx, counts, dispatched, errors_by_slot)
    end
    return manager.slots[Int(slot_idx)]
end

"""
    _start_channel_workers!(manager, jobs, counts, dispatched, errors)

Spawn one long-lived consumer task for each manager worker slot.
"""
function _start_channel_workers!(
    manager::M,
    jobs::Channel{Job},
    counts::Vector{Int},
    dispatched::Vector{Int},
    errors_by_slot::Vector{Vector{Any}},
) where {M<:ProcessManager, Job}
    return ntuple(length(manager.slots)) do slot_idx
        Threads.@spawn _run_channel_worker!(
            manager,
            slot_idx,
            jobs,
            counts,
            dispatched,
            errors_by_slot,
        )
    end
end

"""
    _wait_channel_workers!(manager, tasks)

Wait for channel worker tasks and record unexpected task-level failures.
"""
function _wait_channel_workers!(manager::M, tasks::Tasks) where {M<:ProcessManager, Tasks<:Tuple}
    last_error = nothing
    for task in tasks
        try
            fetch(task)
        catch err
            push!(manager.errors, err)
            last_error = err
        end
    end
    return last_error
end

"""
    _finish_channel_run!(manager, counts, dispatched, errors, task_error)

Merge channel-worker accounting and apply the manager's final flush policy.
"""
function _finish_channel_run!(
    manager::M,
    counts::Vector{Int},
    dispatched::Vector{Int},
    errors_by_slot::Vector{Vector{Any}},
    task_error::Err,
) where {M<:ProcessManager, Err}
    completed_count = sum(counts)
    manager.dispatched += sum(dispatched)
    manager.completions += completed_count
    manager.completions_since_flush += completed_count
    manager.active_count = 0
    manager.free_hint = 1

    threaded_error = _merge_threaded_errors!(manager, errors_by_slot)
    last_error = isnothing(task_error) ? threaded_error : task_error
    manager.throw && !isnothing(last_error) && throw(last_error)

    _apply_flush_policy!(manager, manager.flush_policy; final = true)
    return manager
end

"""
    _channel_run_state(manager)

Create per-slot accounting storage for one channel-worker run.
"""
function _channel_run_state(manager::M) where {M<:ProcessManager}
    slot_count = length(manager.slots)
    counts = zeros(Int, slot_count)
    dispatched = zeros(Int, slot_count)
    errors_by_slot = [Any[] for _ in 1:slot_count]
    return counts, dispatched, errors_by_slot
end

"""
    runchannel!(manager, jobs_channel)

Run a manager with one long-lived worker task per slot, pulling jobs from
`jobs_channel` until that channel is closed and drained.
"""
function runchannel!(manager::M, jobs_channel::Channel{Job}) where {M<:ProcessManager, Job}
    manager.closed && throw(ArgumentError("Cannot run a closed ProcessManager."))
    _has_active_slots(manager) && drain!(manager)

    counts, dispatched, errors_by_slot = _channel_run_state(manager)
    tasks = _start_channel_workers!(manager, jobs_channel, counts, dispatched, errors_by_slot)
    task_error = _wait_channel_workers!(manager, tasks)

    return _finish_channel_run!(manager, counts, dispatched, errors_by_slot, task_error)
end

"""
    runchannel!(manager, jobs; channel_size = length(slots(manager)))

Run `jobs` through a bounded channel. The caller task feeds the channel once,
while one spawned worker task per manager slot stays online until all jobs are
consumed.
"""
function runchannel!(manager::M, jobs::Jobs; channel_size::I = length(slots(manager))) where {M<:ProcessManager, Jobs, I<:Integer}
    manager.closed && throw(ArgumentError("Cannot run a closed ProcessManager."))
    _has_active_slots(manager) && drain!(manager)

    jobs_channel = _manager_job_channel(manager, channel_size)
    counts, dispatched, errors_by_slot = _channel_run_state(manager)
    tasks = _start_channel_workers!(manager, jobs_channel, counts, dispatched, errors_by_slot)

    feed_error = nothing
    try
        _feed_channel_jobs!(jobs_channel, jobs)
    catch err
        feed_error = err
        push!(manager.errors, err)
    finally
        close(jobs_channel)
    end

    task_error = _wait_channel_workers!(manager, tasks)
    combined_error = isnothing(task_error) ? feed_error : task_error
    return _finish_channel_run!(manager, counts, dispatched, errors_by_slot, combined_error)
end

"""
    run!(manager, jobs, ChannelWorkers(; channel_size = ...))

Run `jobs` through the channel-worker manager mode.
"""
function run!(manager::M, jobs::Jobs, mode::CW) where {M<:ProcessManager, Jobs, CW<:ChannelWorkers}
    return runchannel!(manager, jobs; channel_size = _channel_workers_size(mode, manager))
end

"""
    run!(manager, jobs_channel, ChannelWorkers())

Run jobs from an externally managed channel. The call returns after
`jobs_channel` is closed and drained.
"""
function run!(manager::M, jobs_channel::Channel{Job}, mode::CW) where {M<:ProcessManager, Job, CW<:ChannelWorkers}
    return runchannel!(manager, jobs_channel)
end
