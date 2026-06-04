@inline function Base.length(te::RegistryTypeEntry)
    return length(getentries(te))
end

@inline function Base.setindex(rte::RegistryTypeEntry, new::N , idx::Int) where {N}
    entries = getentries(rte)
    new_entries = setindex(entries, new, idx)
    return setfield(rte, :entries, new_entries)
end

@inline getentries(rte::RegistryTypeEntry) = getfield(rte, :entries)
@inline getdynamic(rte::RegistryTypeEntry) = getfield(rte, :dynamic)
@inline getdynamiclookup(rte::RegistryTypeEntry) = getfield(rte, :dynamic_lookup)
@inline getmultipliers(rte::RegistryTypeEntry) = getfield(rte, :multipliers)
@inline getmultiplier(rte::RegistryTypeEntry, idx::Int) = getmultipliers(rte)[idx]
@inline getentries(rtetype::Type{<:RegistryTypeEntry{T,S}}) where {T,S} = tuple(S.parameters...)

setentries(rte::RegistryTypeEntry{T}, newentries) where {T} = RegistryTypeEntry{T,typeof(getdefault(rte)),typeof(newentries), typeof(getdynamic(rte))}(getdefault(rte), newentries, getdynamic(rte), getdynamiclookup(rte))
setdynamic(rte::RegistryTypeEntry{T}, newdynamic) where {T} = RegistryTypeEntry{T,typeof(getdefault(rte)),typeof(getentries(rte)), typeof(newdynamic)}(getdefault(rte), getentries(rte), newdynamic, getdynamiclookup(rte))

function add_dynamic_link!(obj, location::Symbol, idx::Int, rte::RegistryTypeEntry)
    matching_obj = match_by(obj)
    getdynamiclookup(rte)[matching_obj] = idx
    return nothing
end

function remove_dynamic_link!(obj, rte::RegistryTypeEntry)
    matching_obj = match_by(obj)
    delete!(getdynamiclookup(rte), matching_obj)
    return nothing
end

function Base.replace(rte::RegistryTypeEntry{T}, idx::Int, newobj) where {T}
    oldobj = getentries(rte)[idx]
    remove_dynamic_link!(oldobj, rte)
    add_dynamic_link!(newobj, :entries, idx, rte)
    return setindex(rte, newobj, idx)
end

###############################
##### TYPE INFO ##############
###############################

"""
Get the types of static entries
"""
entry_types(rte::Type{<:RegistryTypeEntry{T,E}}) where {T,E} = E.parameters

gettype(rte::Type{<:RegistryTypeEntry{T}}) where T = T
gettype(rte::RegistryTypeEntry) = gettype(typeof(rte))

###############################
##### CHANGING MULTIPLIER #####
###############################

function scale_multipliers!(rte::RegistryTypeEntry{T}, factor) where {T}
    getmultipliers(rte) .*= factor
    return rte
end

function add_multiplier!(rte::RegistryTypeEntry{T}, idx::Int, num::Number) where {T}
    getmultipliers(rte)[idx] += num
    return rte
end
function scale_multiplier!(rte::RegistryTypeEntry{T}, idx::Int, factor::Number) where {T}
    getmultipliers(rte)[idx] *= factor
    return rte
end

############################
######### Finding ##########
############################

@inline function static_findfirst_match(rte::RegistryTypeEntry, val)
    id = @inline match_by(val)
    @inline static_findfirst_match(rte, Val(id))
end

## IN GENERATEDFUNCTIONS
# @inline @generated function static_findfirst_match(rte::RegistryTypeEntry{T,S}, v::Val{value}) where {T,S,value}
#     idx = findfirst(x -> match(value, x), entry_types(rte))
#     return :($idx)
# end

@inline dynamic_find_match(rte::RegistryTypeEntry{T}, val) where {T} = get(getdynamiclookup(rte), match_by(val), nothing)
@inline findfirst_match(rte::RegistryTypeEntry, val) = isstaticallyfindable(val) ? static_findfirst_match(rte, val) : dynamic_find_match(rte, val)

##########################
######## GETTERS #########
##########################
function Base.getindex(te::RegistryTypeEntry, obj)
    if isstaticallyfindable(obj)
        return static_get(te, obj)
    end
    entry = dynamic_get(te, obj)
    isnothing(entry) && error("No matching entry found for value: $obj with matcher $(match_by(obj))\nin RegistryTypeEntry of type $(gettype(te))\nwith entries: $(getentries(te))\nand matchers $(match_by.(getentries(te)))")
    return entry
end

function Base.getindex(te::RegistryTypeEntry, idx::Int)
    getentries(te)[idx]
end

"""
Match Exact with value
"""
@inline function static_get(rte::RegistryTypeEntry, val::V) where V 
    idx = static_findfirst_match(rte, val)
    if isnothing(idx)
        error("No matching entry found for value: $val with matcher $(match_by(val))\nin RegistryTypeEntry of type $(gettype(rte))\nwith entries: $(getentries(rte))\nand matchers $(match_by.(getentries(rte)))")
    end
    return getentries(rte)[idx]
end


###########################
##### MERGING ENTRIES #####
###########################

@inline function Base.merge(entry1::RegistryTypeEntry{T}, entry2::RegistryTypeEntry{T}) where {T}
    for (identifiable, multiplier) in getentries(entry2)
        entry1, _ = @inline add(entry1, identifiable, multiplier)
    end

    return entry1
end

#############################
##### VALUE LOOKUPS #########
#############################

#=
Match either a scoped or non scope value with one of the entries
This is faster for runtime, slower for inlining
=#

dynamic_lookup(rte::RegistryTypeEntry{T}, val) where {T} = get(getdynamiclookup(rte), match_by(val), nothing)

@inline function dynamic_get(rte::RegistryTypeEntry{T}, val) where {T}
    idx = dynamic_lookup(rte, val)
    if isnothing(idx)
        return nothing
    end
    return getentries(rte)[idx]
end



############################
######## ITERATE  ##########
############################

function Base.iterate(te::RegistryTypeEntry, state = 1)
    if state > length(te)
        return nothing
    else
        return ((getentries(te)[state], getmultipliers(te)[state]), state + 1)
    end
end


###############################
########## Names #############
###############################
function all_named_algos(te::Union{RegistryTypeEntry, Type{<:RegistryTypeEntry}})
    getentries_list = getentries(te)
end

"""
Context names
"""
function all_keys(te::Union{RegistryTypeEntry, Type{<:RegistryTypeEntry}})
    getkey.(getentries(te))
end

"""
Change the context name of an entry
from oldname to newname
"""
function replacecontextkeys(te::RegistryTypeEntry, oldname, newname::Symbol)
    idx = findfirst(==(oldname), all_keys(te))
    if isnothing(idx)
        return te
    end
    return setindex(te, setcontextkey(te[idx], newname), idx)
end

"""
From a dict that contains oldname => newname
Change all referenced context names in the RegistryTypeEntry
"""
function replacecontextkeyss(te::RegistryTypeEntry, changed_names::Dict{Symbol,Symbol})
    ps = pairs(changed_names)
    unrollreplace_splat(te, ps...) do rte, (oldname, newname)
        setcontextkey(rte, newname)
    end
end

@inline findkey(te::Union{RTE, Type{<:RTE}}, key::Symbol) where RTE <: RegistryTypeEntry = findkey(te, Val(key))
@inline @generated function findkey(te::Union{RTE, Type{<:RTE}}, ::Val{key}) where {RTE <: RegistryTypeEntry, key}
    entries = getentries(RTE)
    idx = findfirst(x -> getkey(x) == key, entries)
    if isnothing(idx)
        return :(nothing)
    else
        return :($idx)
    end
end

@inline Base.haskey(te::Union{RTE, Type{<:RTE}}, key::Symbol) where RTE <: RegistryTypeEntry = !isnothing(findkey(te, key))

@inline _registry_findall_type(::Type{E}) where {E} = E
@inline _registry_findall_type(::Type{<:AbstractIdentifiableAlgo{F}}) where {F} = F
@inline _registry_findall_matches(::Type{E}, ::Type{T}) where {E, T} = _registry_findall_type(E) <: T

@inline _registry_findall_type_entries(::Type{T}, ::Tuple{}) where {T} = ()
@inline function _registry_findall_type_entries(::Type{T}, entries::Tuple) where {T}
    head = first(entries)
    tail_matches = _registry_findall_type_entries(T, Base.tail(entries))
    return _registry_findall_matches(typeof(head), T) ? (head, tail_matches...) : tail_matches
end

"""
Return all registered entries whose algorithm type is a subtype of `T`.

Entries are returned as they are stored in the registry, usually identifiable
wrappers. For identifiable entries, matching uses the wrapped algorithm type.
"""
@inline Base.findall(::Type{T}, te::RegistryTypeEntry) where {T} =
    _registry_findall_type_entries(T, getentries(te))

###################################
########## REBUILDING #############
###################################

function rebuild(f, rte::RegistryTypeEntry)
    @DebugMode println("Rebuilding RegistryTypeEntry for type ", gettype(rte))
 
    new_entries = f.(getentries(rte))
    @DebugMode "New Entries: $(new_entries)"

    return setfield(rte, :default, new_default) |> x -> setfield(x, :entries, new_entries)
end



###############################
##### SHOWING ENTRIES ##########
###############################

function Base.show(io::IO, rte::RegistryTypeEntry{T}) where {T}
    println(io, "RegistryTypeEntry for type: $(T)")
    if length(getentries(rte)) == 0
    else
        entries = getentries(rte)
        limit = get(io, :limit, false)
        n = length(entries)
        head = 3
        tail = 2
        if !limit || n <= head + tail + 1
            for (idx, entry) in enumerate(entries)
                println(io, "\t", idx, " \t => ", entry, " x ", getmultiplier(rte,idx))
            end
        else
            for idx in 1:head
                entry = entries[idx]
                println(io, "\t", idx, " \t => ", entry, " x ", getmultiplier(rte,idx))
            end
            println(io, "\t...")
            for idx in (n - tail + 1):n
                entry = entries[idx]
                println(io, "\t", idx, " \t => ", entry, " x ", getmultiplier(rte,idx))
            end
        end
    end
end
