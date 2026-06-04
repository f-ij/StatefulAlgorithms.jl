export isfree, isused, isrunning, ispaused, isdone, isidle, status
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
ispaused(p::Process) = !isnothing(p.task) && p.paused

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