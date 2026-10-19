export isfree, isused, isrunning, ispaused, isdone, isidle, status
"""
Is it running or not
"""
status(p::AnyProcess) = isrunning(p) ? :Running : :Idle

"""
P has a task and it is currently running
"""
isstarted(p::AnyProcess) = !isnothing(p.task) && istaskstarted(p.task)

"""
P has a task and it is currently running
"""
isrunning(p::AnyProcess) = isstarted(p) && !istaskdone(p.task)

"""
P had a task and it was paused
"""
ispaused(p::AnyProcess) = !isnothing(p.task) && (@atomic p.paused)

"""
P had a task and it finished running, without being flagged as paused
"""
isdone(p::AnyProcess) = !isnothing(p.task) && istaskdone(p.task) && !ispaused(p)


"""
P is done or paused, i.e. not doing anything
"""
isidle(p::AnyProcess) = isdone(p) || ispaused(p) || !isstarted(p)

"""
Can be used for a new process
"""
isfree(p::AnyProcess) = !isrunning(p) && !ispaused(p)

"""
Is currently used for running,
    can be paused
"""
isused(p::AnyProcess) = isrunning(p) || ispaused(p)
