function replace_name!(pa::LA, idx, newname::Symbol) where {LA<:LoopSpec}
    oldnames = getnames(pa)
    newnames = ntuple(i -> i == idx ? newname : oldnames[i], length(oldnames))
    pa.names = newnames
end

# getregistry(pa::LoopAlgorithm) = pa.registry
getregistry(a::Any) = error("No registry found for object of type $(typeof(a))")

@inline _attach_registry(cla::LA, ::NameSpaceRegistry) where {LA<:LoopSpec} = cla

"""
Update every key in a plan tree to the names in `base_registry`: the children (recursively), the states, the route/share
wiring (a child's routes stay that child's) and the options; on a `LoopAlgorithm` also the root options it collected,
and the registry is attached.
"""
function update_keys(plan::P, base_registry::NameSpaceRegistry) where {P<:AbstractPlan}
    wiring = update_keys.(scoped_wiring_values(plan), Ref(base_registry))
    plan = rebuild_loopalgorithm_funcs(plan, update_keys.(getalgos(plan), Ref(base_registry)))
    plan = setwiring(plan, wiring)
    return _with_states_options(plan, update_keys.(getstates(plan), Ref(base_registry)), update_keys.(getoptions(plan), Ref(base_registry)))
end

function update_keys(la::LoopAlgorithm, base_registry::NameSpaceRegistry)
    la = setfield(la, :plan, update_keys(getplan(la), base_registry))
    la = setoptions(la, update_keys.(getoptions(la), Ref(base_registry)))
    return _attach_registry(la, base_registry)
end

"""A child-scoped route or share: both its child and the route or share get the new keys."""
update_keys(option::LocalPlanOption, reg::NameSpaceRegistry) =
    LocalPlanOption(update_keys(getfield(option, :owner), reg), update_keys(getfield(option, :option), reg))

function recursive_update_cla_names(a::Any, ::Any)
    return a
end

struct InstantiateError <: Exception
    f
    err::Exception
end

function Base.showerror(io::IO, e::InstantiateError)
    print(io, "instantiate(", e.f, ") failed. If you passed a Type, it must have a zero-arg constructor. Caused by: ")
    showerror(io, e.err)
end

function instantiate(f)
    try
        if Base.issingletontype(f)
            return f.instance
        end
        
        return f isa Type ? f() : f
    catch err
        throw(InstantiateError(f, err))
    end
end
