function replace_name!(pa::LA, idx, newname::Symbol) where {LA<:LoopSpec}
    oldnames = getnames(pa)
    newnames = ntuple(i -> i == idx ? newname : oldnames[i], length(oldnames))
    pa.names = newnames
end

# getregistry(pa::LoopAlgorithm) = pa.registry
getregistry(a::Any) = error("No registry found for object of type $(typeof(a))")

@inline _attach_registry(cla::LA, ::NameSpaceRegistry) where {LA<:LoopSpec} = cla

"""
Obtain all the registriees, merge them and update the names downwards in the algorithm accordingly: the children, the
route/share wiring (a child's routes stay that child's), the states and the options (on a `LoopAlgorithm`, the root
options it collected).
"""
function update_keys(cla::LA, base_registry::NameSpaceRegistry) where {LA<:LoopSpec}
    oldsfuncs = getalgos(cla)
    @DebugMode "Updating names for LoopAlgorithm: $cla using base registry: $base_registry"
    newfuncs = update_keys.(oldsfuncs, Ref(base_registry)) #Recursive replace LoopAlgorithm
    oldwiring = scoped_wiring_values(getplan(cla))
    newwiring = update_keys.(oldwiring, Ref(base_registry))
    oldstates = getstates(cla)
    newstates = update_keys.(oldstates, Ref(base_registry))
    oldoptions = getoptions(cla)
    newoptions = update_keys.(oldoptions, Ref(base_registry))
    # newfuncs = update_name.(funcs, Ref(base_registry)) # Rename IdentifiableAlgos and remove old registries
    # updated_registry = update_keys(getregistry(cla), base_registry)
    cla = rebuild_loopalgorithm_funcs(cla, newfuncs)
    cla = setwiring(cla, newwiring)
    cla = setstates(cla, newstates)
    cla = setoptions(cla, newoptions)
    cla = _attach_registry(cla, base_registry)
    return cla
    # pa_new = newfuncs(pa, funcs)
    # update_keys(pa_new, base_registry)
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
