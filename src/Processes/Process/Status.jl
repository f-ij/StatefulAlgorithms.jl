#=
The status of a `Process` as the user asks for it: running, paused, done, idle, free, used; and how far its run is
(`progress`, `est_remaining`, `incs_per_sec`).
=#

export isfree, isused, isrunning, ispaused, isdone, isidle, status, progress, est_remaining
"""
Is it running or not
"""
status(p::Process) = isrunning(p) ? :Running : :Idle

"""
P has a task and it is currently running
"""
isstarted(p::Process) = !isnothing(p.task) && istaskstarted(p.task)

"""
P has a task and it is currently running
"""
isrunning(p::Process) = isstarted(p) && !istaskdone(p.task)

"""
P had a task and it was paused
"""
ispaused(p::Process) = !isnothing(p.task) && (@atomic getsession(p).paused)

"""
P had a task and it finished running, without being flagged as paused
"""
isdone(p::Process) = !isnothing(p.task) && istaskdone(p.task) && !ispaused(p)


"""
P is done or paused, i.e. not doing anything
"""
isidle(p::Process) = isdone(p) || ispaused(p) || !isstarted(p)

"""
Can be used for a new process
"""
isfree(p::Process) = !isrunning(p) && !ispaused(p)

"""
Is currently used for running,
    can be paused
"""
isused(p::Process) = isrunning(p) || ispaused(p)

"""
Gives the maximum loop index for a process
"""
function maximum_loopidx(p::Process)
    return repeats(p)
end

"""
    progress(process)

Return the fraction of the configured finite repeat bound already executed.

The value is clamped to `[0, 1]`. Indefinite lifetimes report `0.0`, while a
completed zero-repeat process reports `1.0`.
"""
function progress(p::Process)
    total = maximum_loopidx(p)
    isfinite(total) || return 0.0
    total > 0 || return isdone(p) ? 1.0 : 0.0

    completed = max(getlidx(p) - 1, 0)
    return clamp(completed / total, 0.0, 1.0)
end

"""
Gives an estimate of the remaining time for the process
"""
function est_remaining(p::Process)
    # TODO: progress can now be 0.0 (before the first step, or after close), so rt / prog is Inf and floor(Int, Inf) throws InexactError.
    prog = progress(p)
    rt = runtime(p)
    total_time = rt / prog
    remaining_sec = total_time - rt
    total_hours = floor(Int, total_time / 3600)
    total_minutes = floor(Int, mod(total_time, 3600) / 60)
    total_seconds = floor(Int, mod(total_time, 60))
    hours = floor(Int, remaining_sec / 3600)
    minutes = floor(Int, mod(remaining_sec, 3600) / 60)
    seconds = floor(Int, mod(remaining_sec, 60))
    println("Estimated time to completion: $total_hours:$total_minutes:$total_seconds")
    println("Of which remaining: $hours:$minutes:$seconds")
end

function incs_per_sec(p::Process)
    loopidx(p) / runtime(p)
end
