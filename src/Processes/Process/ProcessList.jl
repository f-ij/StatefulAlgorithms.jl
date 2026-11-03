#=
The list of live processes (`processlist`), by id, so a process can be found and quit without a reference to it.
=#
"""
Module dict for managing alive processes if no active reference is alive
"""
const processlist = Dict{UUID, WeakRef}()
register_process!(p) = let id = uuid1(); processlist[id] = WeakRef(p); id end
function remove_process!(p::Process)
    close(p)
    pop!(processlist, p.id, nothing)
end

# function Base.finalizer(p::Process)
#     quit(p)
#     delete!(processlist, p.id)
# end
