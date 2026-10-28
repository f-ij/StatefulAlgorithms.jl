# List of processes in use
"""
Module dict for managing alive processes if no active reference is alive
"""
const processlist = Dict{UUID, WeakRef}()
register_process!(p) = (processlist[p.list_ref] = WeakRef(p); p.list_ref)
# The finalizer: drops the process's entry. No `close`: a process is only collected when nothing holds it, so no task
# runs it and a paused one can never be resumed. Untyped, so it compiles once (as `close(p)` it compiled for every set
# of `Unique` handles, 12 ms, when the garbage collector ran it).
Base.@nospecializeinfer remove_process!(@nospecialize(p::Process)) = (pop!(processlist, getfield(p, :list_ref), nothing); nothing)
