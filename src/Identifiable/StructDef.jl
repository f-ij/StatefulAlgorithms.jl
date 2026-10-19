######################################
########## Scoped Algorithms #########
######################################
export IdentifiableAlgo, Unique, Identified

"""
Algorithm assigned to a namespace in a context
    Ids can be used te separate two algorithms with the same name and function

    The scopename will be set before when building a LoopAlgorithm, through the a NameSpaceRegistry
        This is done automatically when composing an algorithm and generally will be along the lines of 
        "Type Name of func"_num
    
    The scopename tells the algorithm where to look in the total context

    Id makes two IdentifiableAlgos different even if they have the same name and function
    This can be used to create multiple instances of the same algorithm with each their own state

    VarAliases are bridges from the scope to the runtime (init, step!, and cleanup) variables that
        the algorithm can get from a context. An alias definex Varname_in_subcontext => Varname_in_algorithm 

    AlgoName can be used when fusing multiple algorithms to give them custom names

"""
struct IdentifiableAlgo{F, Id, VarAliases, AlgoName, Key, M} <: AbstractIdentifiableAlgo{F, Id, VarAliases, AlgoName, Key}
    func::F
    # The matcher as data when it carries data (`UniquePlanId`): `Id` is then its type (`static_id`). `nothing`
    # (`M = Nothing`, no extra bytes) for every other id, which `Id` holds itself.
    matcher::M
end

# A handle whose id is all in its type.
IdentifiableAlgo{F, Id, VarAliases, AlgoName, Key}(func) where {F, Id, VarAliases, AlgoName, Key} =
    IdentifiableAlgo{F, Id, VarAliases, AlgoName, Key, Nothing}(func, nothing)

"""
    identifiable_with_id(func, id, aliases, algoname, key) -> IdentifiableAlgo

The handle of `func` with id `id`: `static_id(id)` in its type, and `id` in its `matcher` field when it carries data.
"""
Base.@nospecializeinfer function identifiable_with_id(@nospecialize(func), @nospecialize(id), @nospecialize(aliases), @nospecialize(algoname), @nospecialize(key))
    sid = static_id(id)
    field = sid === id ? nothing : id
    # Made with `new_instance`: a handle with data in its matcher (`Unique`) is a new type for every uuid.
    return new_instance(Core.apply_type(IdentifiableAlgo, typeof(func), sid, aliases, algoname, key, typeof(field)), func, field)
end

"""The handle `sa` with matcher `id` (`identifiable_with_id`); everything else is kept."""
Base.@nospecializeinfer function setmatcher(@nospecialize(sa::IdentifiableAlgo), @nospecialize(id))
    p = typeof(sa).parameters
    return identifiable_with_id(getfield(sa, :func), id, p[3], p[4], p[5])
end
