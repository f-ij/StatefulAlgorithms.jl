# List of processes in use
"""
Module dict for managing alive processes if no active reference is alive
"""
const processlist = Dict{UUID, WeakRef}()
register_process!(p) = let id = uuid1(); processlist[id] = WeakRef(p); id end
function remove_process!(p::Process)
    close(p)
    pop!(processlist, p.id, nothing)
end
