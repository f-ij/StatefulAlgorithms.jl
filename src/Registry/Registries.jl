struct RegistryLocation{T, Int} end
RegistryLocation(T, idx) = RegistryLocation{T, idx}()
gettype(loc::RegistryLocation{T, idx}) where {T, idx} = T
getidx(loc::RegistryLocation{T, idx}) where {T, idx} = idx


getentries(reg::NameSpaceRegistry{T}) where {T} = getfield(reg, :entries)
Base.getindex(reg::NameSpaceRegistry, idx::Int) = getentries(reg)[idx]
Base.length(reg::NameSpaceRegistry) = length(getentries(reg))

@inline function Base.setindex(reg::NameSpaceRegistry{T}, newentry, idx::Int) where {T}
    old_entries = getentries(reg)
    new_entries = @inline tuple_setindex(old_entries, newentry, idx)
    return NameSpaceRegistry{typeof(new_entries)}(new_entries)
end

@inline function Base.setindex(reg::NameSpaceRegistry, newentry, T::Type)
    fidx = find_typeidx(reg, T)
    if isnothing(fidx)
        error("Type $T not found in registry")
    end
    return Base.setindex(reg, newentry, fidx)
end

"""
Get the actual types of the typeentries
"""
@inline function typeentry_types(reg::Union{NameSpaceRegistry{T}, Type{NameSpaceRegistry{T}}}) where {T}
    param_svec = T.parameters
    if isempty(param_svec)
        return Tuple{}
    end
    entrytypes = T.parameters
    tuple(entrytypes...)
end


"""
Types of entries as a tuple type Tuple{Type1, Type2, ...}
"""
@inline function entrytypes(reg::Union{NameSpaceRegistry{T}, Type{NameSpaceRegistry{T}}}) where {T}
    param_svec = T.parameters
    if isempty(param_svec)
        return Tuple{}
    end
    entrytypes = T.parameters
    datatypes = gettype.(entrytypes)
    Tt = Tuple{datatypes...}
    return Tt
end

"""
Types of entries as a tuple statically (Type1, type2, ...)
"""
@inline function entrytypes_iterator(reg::Union{NameSpaceRegistry{T}, Type{NameSpaceRegistry{T}}}) where {T}    
    param_svec = T.parameters
    if isempty(param_svec)
        return tuple()
    end
    datatypes = ntuple(i -> gettype(param_svec[i]), length(param_svec))
    return datatypes
end

entrytypes_iterator(reg::NameSpaceRegistry) = entrytypes_iterator(typeof(reg))

"""
Find the index in the entries for a given type T
"""
@inline find_typeidx(regt::Type{<:NameSpaceRegistry}, obj) = _find_typeidx(regt, typeof(obj))
@inline find_typeidx(regt::Type{<:NameSpaceRegistry}, typ::Type) = _find_typeidx(regt, typ)
@inline find_typeidx(reg::NameSpaceRegistry, obj) = find_typeidx(typeof(reg), obj)

### _find_typeidx in generated functions folder ###

# """
# Non-generated helper of find_typeidx for use in other generated functions
# """
# function nongen_find_typeidx(reg::Type{<:NameSpaceRegistry}, typ::Type{T}) where {T}
#     it = entrytypes_iterator(reg)
#     index = findfirst(t -> T <: t, it)
#     return index
# end



# registry_entrytype(tt::Type{Type{T}}) where T = match_by(T) # For generated function compatibility




########################################
############## Interface ###############
########################################



#########################
######### ADDING ########
#########################
"""
Add an instance and get new registry and a named instance back
"""
function add(reg::NameSpaceRegistry{T}, obj, multiplier = 1.; withkey = nothing) where {T}
    if obj isa NameSpaceRegistry
        error("Cannot add a NameSpaceRegistry to another NameSpaceRegistry")
    end

    @DebugMode "Adding object: $obj to registry: $reg with multiplier: $multiplier and name: $withkey"
    entry_t = assign_entrytype(obj)
    fidx = find_typeidx(reg, entry_t)
    if isnothing(fidx) # New Entry
        newentry = RegistryTypeEntry{entry_t}()
        newentry, keyed_obj = add(newentry, obj, multiplier; withkey)
        if entry_t <: AlgoState # States go first
            new_entries = (newentry, getentries(reg)...)
        else
            new_entries = (getentries(reg)..., newentry)
        end
        return NameSpaceRegistry{typeof(new_entries)}(new_entries), keyed_obj
    else # Type was found
        entry = getentries(reg)[fidx]
        
        newentry, keyed_obj = add(entry, obj, multiplier; withkey)
        # return newentry
        return Base.setindex(reg, newentry, fidx), keyed_obj
    end
end

"""
Add multiple objects to the registry with the same multiplier
"""
function addall(reg::NSR, objs::O, mults::M) where {NSR<:NameSpaceRegistry,O<:Tuple,M<:Tuple}
    reg = unrollreplace(reg, (zip(objs, mults)...,)) do r, obj_mult
        obj, mult = obj_mult
        newreg, _ = add(r, obj, mult)
        return newreg
    end
end

#########################
##### DRAFT REGISTRY ####
#########################
#=
Building a registry from plain values. Adding to a `NameSpaceRegistry` one algorithm at a time (`add`) gives a new
registry type after every add, and Julia compiles each add anew. A `RegistryDraft` holds the same data as plain
values (entry types, keyed algorithms, multipliers, lookup tables) and follows the same rules as `add`.

The draft works in two modes, with the same functions:
- on values: `draft_add!` gets the algorithms themselves, and `build_registry` builds the registry from them;
- on types: `draft_add!` gets `_GenItem`s, an algorithm known only by its type and the expression that reads it
  from the plan. This is how `setup_registry_and_keyed_algos` (GeneratedCode/Preparation.jl) works out the layout of
  a plan's registry while compiling, and `registry_expr` gives the code that builds that registry from the plan.
  Every decision in `draft_add!` is made from the types; a step that needs the values (a merge, or an object that
  is not an `IdentifiableAlgo` handle) throws `_NeedsValues`, and the registry is then built on values at run time.

The functions below take types and algorithms as values (`@nospecialize`), so they are compiled once, not per plan.
=#

"""
    _GenItem(T, ex, fields = nothing)

A value known only by its type while a registry layout is worked out at compile time: its type `T` and the
expression `ex` that gives it at run time (reading it from the plan with `getfield`, or building it). `fields`, when
known, holds the `_GenItem`s of its fields, for a value that `ex` builds.
"""
struct _GenItem
    T::Any
    ex::Any
    fields::Union{Nothing, Vector{Any}}
end
_GenItem(@nospecialize(T), @nospecialize(ex)) = _GenItem(T, ex, nothing)

"""Thrown while a registry layout is worked out from types, when a step needs the values themselves."""
struct _NeedsValues <: Exception end

"""The type of `x`: of the value, or the type a `_GenItem` stands for."""
_itemtype(@nospecialize(x)) = x isa _GenItem ? x.T : typeof(x)

"""
    _ifield(x, f) -> field

Field `f` (a name or an index) of `x`: the value's field, or for a `_GenItem` a `_GenItem` of the field (its declared
type and `getfield` on `x`'s expression). A field whose value decides something must have a concrete declared type:
see `_iconcrete`.
"""
Base.@nospecializeinfer function _ifield(@nospecialize(x), f::Union{Symbol, Int})
    x isa _GenItem || return getfield(x, f)
    if !isnothing(x.fields)
        return x.fields[f isa Int ? f : Base.fieldindex(x.T, f)]
    end
    return _GenItem(fieldtype(x.T, f), Expr(:call, getfield, x.ex, QuoteNode(f)))
end

"""`x`, after checking that a `_GenItem`'s type is concrete (else its value, not its type, decides; throws `_NeedsValues`)."""
_iconcrete(@nospecialize(x)) = (x isa _GenItem && !isconcretetype(x.T) && throw(_NeedsValues()); x)

"""The number of fields of `x` (of the type a `_GenItem` stands for)."""
_infields(@nospecialize(x)) = x isa _GenItem ? fieldcount(x.T) : nfields(x)

"""
    _ituple(xs, like) -> tuple

The tuple of `xs`: a tuple of the values, or, when `like` is a `_GenItem`, a `_GenItem` of the tuple.
"""
Base.@nospecializeinfer function _ituple(xs::Vector{Any}, @nospecialize(like))
    like isa _GenItem || return Tuple(xs)
    types = Any[_itemtype(x) for x in xs]
    return _GenItem(Tuple{types...}, Expr(:tuple, Any[x.ex for x in xs]...), xs)
end

"""The constant `v`, as a `_GenItem` when `like` is one."""
_iconst(@nospecialize(v), @nospecialize(like)) = like isa _GenItem ? _GenItem(typeof(v), QuoteNode(v)) : v

"""
    _value_trait(f, F) -> f(x)

`f(x)` for a value `x` of type `F`, found from `F` alone: `f` of `F`'s only value when `F` has just one (exactly as
on the value), else `f(F)`. The second is right for every method of the traits this is used for (`autokey_basename`,
`registry_allowmerge`) that the package defines, which take the type as well as the value; a method for an
algorithm that has fields must take the type too (`Union{MyAlgo, Type{<:MyAlgo}}`) to be seen here.
(Reflection such as `which` cannot be used while a generated function is being generated, so the method a value
would get cannot be looked up.)
"""
_value_trait(@nospecialize(f), @nospecialize(F)) = Base.issingletontype(F) ? f(F.instance) : f(F)

"""
    RegistryDraft()

A registry under construction, as plain values: per entry type, in registry order, the type (`Lin`), the keyed
algorithms (`Lin_1`, `Lin_2`, ...), their multipliers and the runtime lookup table (`dynamic_lookup`), and the
matcher of each keyed algorithm's type (`match_by`, kept to find matches without recomputing it). Fill it with
`draft_add!`, then `build_registry` (on values) or `registry_expr` (on types) gives the `NameSpaceRegistry` that the
same adds with `add` would give.
"""
struct RegistryDraft
    types::Vector{Any}
    entries::Vector{Vector{Any}}
    multipliers::Vector{Vector{Float64}}
    lookups::Vector{Dict{LookupKey,Int}}
    matchers::Vector{Vector{Any}}
end
RegistryDraft() = RegistryDraft(Any[], Vector{Any}[], Vector{Float64}[], Dict{LookupKey,Int}[], Vector{Any}[])

"""
    draft_add!(draft, obj, multiplier) -> keyed

Add `obj` with `multiplier` to `draft` and return it as the registry stores it (keyed, for example `Lin_1`); the
same as `add(reg, obj, multiplier)` on a `NameSpaceRegistry`. A new entry type goes first if it is a state
(`AlgoState`), last otherwise. Within an entry type, an algorithm that matches one already there (`match_by`, or the
lookup table for values that are not `isbits`) is not added again: its multiplier is added to that one's, a given key
replaces an automatic one, and mergeable entries (`registry_allowmerge`) are merged.

`obj` can be a `_GenItem` (see the top of this section): it must then be an `IdentifiableAlgo` handle, whose type
decides everything, and a merge throws `_NeedsValues`.
"""
Base.@nospecializeinfer function draft_add!(draft::RegistryDraft, @nospecialize(obj), @nospecialize(multiplier))
    T = _itemtype(obj)
    T <: NameSpaceRegistry && error("Cannot add a NameSpaceRegistry to another NameSpaceRegistry")
    T === Nothing && error("Trying to add `nothing` to a registry")
    gen = obj isa _GenItem
    gen && !(isconcretetype(T) && T <: IdentifiableAlgo) && throw(_NeedsValues())
    entry_t = assign_entrytype(gen ? T : obj)
    t = 0
    for i in eachindex(draft.types)
        if entry_t <: draft.types[i]
            t = i
            break
        end
    end
    if t == 0
        if entry_t <: AlgoState   # states go first
            pushfirst!(draft.types, entry_t); pushfirst!(draft.entries, Any[])
            pushfirst!(draft.multipliers, Float64[]); pushfirst!(draft.lookups, Dict{LookupKey,Int}()); pushfirst!(draft.matchers, Any[])
            t = 1
        else
            push!(draft.types, entry_t); push!(draft.entries, Any[])
            push!(draft.multipliers, Float64[]); push!(draft.lookups, Dict{LookupKey,Int}()); push!(draft.matchers, Any[])
            t = length(draft.types)
        end
    end
    entries, mults, lookup, matchers = draft.entries[t], draft.multipliers[t], draft.lookups[t], draft.matchers[t]

    fidx = _draft_findmatch(entries, matchers, lookup, obj)
    if isnothing(fidx)
        keyed = _draft_autokey(obj, length(entries) + 1)
        push!(mults, multiplier)
        push!(entries, keyed)
        push!(matchers, _UNSET_MATCHER)
        lookup[_draft_lookup_key(keyed)] = length(entries)
        return keyed
    end
    # The same rules as `add(::RegistryTypeEntry, ...)`: a given key replaces an automatic one, given keys must agree,
    # mergeable entries are merged.
    if _draft_hasautokey(entries[fidx]) && _draft_haskey(obj)
        _draft_replace!(entries, lookup, matchers, fidx, obj)
    end
    if _draft_hasgivenkey(entries[fidx]) && _draft_hasgivenkey(obj)
        @assert _draft_getkey(entries[fidx]) == _draft_getkey(obj) "Trying to add an entry with name $(_draft_getkey(obj)) but an entry with the same type already exists with name $(_draft_getkey(entries[fidx]))"
    end
    if gen
        # A merge combines the values; from the types it is only known whether one happens.
        _draft_allowmerge(entries[fidx], obj) && !_same_unique_entry_types(_itemtype(entries[fidx]), T) && throw(_NeedsValues())
    elseif registry_allowmerge(entries[fidx], obj) && !_same_unique_entry(entries[fidx], obj)
        _draft_replace!(entries, lookup, matchers, fidx, merge(entries[fidx], obj))
    end
    mults[fidx] += multiplier
    return entries[fidx]
end

# Keys of an entry or of an object being added: of the value, or from the handle type of a `_GenItem`.
_draft_getkey(@nospecialize(x)) = x isa _GenItem ? x.T.parameters[5] : getkey(x)
_draft_haskey(@nospecialize(x)) = x isa _GenItem ? x.T.parameters[5] != Symbol() : haskey(x)
function _draft_hasautokey(@nospecialize(x))
    x isa _GenItem || return hasautokey(x)
    key = x.T.parameters[5]
    key == Symbol() && return false
    return startswith(string(key), string(_value_trait(autokey_basename, x.T.parameters[1]), "_"))
end
_draft_hasgivenkey(@nospecialize(x)) = _draft_haskey(x) && !_draft_hasautokey(x)

"""Whether a `_GenItem` handle `b` would be merged into the entry `a` (`registry_allowmerge` of two handles), from their types."""
Base.@nospecializeinfer function _draft_allowmerge(a::_GenItem, b::_GenItem)
    _draft_haskey(a) && _draft_haskey(b) && _draft_getkey(a) == _draft_getkey(b) || return false
    return _value_trait(registry_allowmerge, a.T.parameters[1]) || _value_trait(registry_allowmerge, b.T.parameters[1])
end

"""`_same_unique_entry` for two handle types: the same id given to them (`Unique`)."""
_same_unique_entry_types(@nospecialize(A), @nospecialize(B)) =
    A.parameters[2] isa Union{SimpleId, NormalizedId} && A.parameters[2] == B.parameters[2]

"""
    _RuntimeKey(id, ex)

Stands for a runtime lookup key while a layout is worked out from types: the key of a normalized handle comes from
its `reconstructor` value (`dynamic_lookup_key`), which `ex` reads. Equal for the same normalized id `id`.
"""
struct _RuntimeKey
    id::Any
    ex::Any
end
Base.isequal(a::_RuntimeKey, b::_RuntimeKey) = isequal(a.id, b.id)
Base.hash(a::_RuntimeKey, h::UInt) = hash(a.id, hash(_RuntimeKey, h))

"""The lookup key of `x` (`dynamic_lookup_key`); for a `_GenItem`, from its type, or a `_RuntimeKey` for a normalized handle."""
Base.@nospecializeinfer function _draft_lookup_key(@nospecialize(x))
    x isa _GenItem || return dynamic_lookup_key(x)
    x.T.parameters[6] <: IdReconstructor && return LookupKey(_RuntimeKey(x.T.parameters[2], x.ex))
    return dynamic_lookup_key(x.T)
end

"""
The index of the entry in `entries` that `obj` matches, or `nothing`; as `findfirst_match` on a `RegistryTypeEntry`.
`matchers` keeps the matcher of each entry's type once it has been computed.
"""
Base.@nospecializeinfer function _draft_findmatch(entries::Vector{Any}, matchers::Vector{Any}, lookup::Dict{LookupKey,Int}, @nospecialize(obj))
    gen = obj isa _GenItem
    gen || isstaticallyfindable(obj) || return get(lookup, dynamic_lookup_key(obj), nothing)
    # As the generated `static_findfirst_match`, which calls `match(match_by(obj), entry type)`: `match` compares the
    # matchers of both (a matcher is its own), and the entry types' matchers are kept in `matchers`.
    value = match_by(gen ? obj.T : obj)
    value isa AbstractMatcher || (value = match_by(value))
    # Concrete types (algorithms often match by their type, `Lin{1}`) are equal only if identical: compared without
    # calling `==`.
    concrete = value isa DataType && isconcretetype(value)
    for i in eachindex(matchers)
        matchers[i] === _UNSET_MATCHER && (matchers[i] = match_by(_itemtype(entries[i])))
        m = matchers[i]
        if concrete && m isa DataType && isconcretetype(m)
            value === m && return i
        elseif value == m
            return i
        end
    end
    return nothing
end

struct _UnsetMatcher end
const _UNSET_MATCHER = _UnsetMatcher()   # an entry whose type's matcher is not computed yet

"""Put `new` at `idx` in `entries`, moving its key in `lookup` from the old entry to `new` and resetting its matcher; as `replace` on a `RegistryTypeEntry`."""
Base.@nospecializeinfer function _draft_replace!(entries::Vector{Any}, lookup::Dict{LookupKey,Int}, matchers::Vector{Any}, idx::Int, @nospecialize(new))
    delete!(lookup, _draft_lookup_key(entries[idx]))
    lookup[_draft_lookup_key(new)] = idx
    entries[idx] = new
    matchers[idx] = _UNSET_MATCHER
    return nothing
end

"""
    _draft_autokey(obj, i) -> keyed

`Autokey(obj, i)`: `obj` with the automatic key of the `i`-th entry of its type (`Lin_2`), or unchanged if it has a
key. For a handle (`IdentifiableAlgo`) the key is set on its type here, as a value, so nothing is compiled per handle
type and index (`Autokey` builds the key with `static_symbol`, one generated method per key); other values go to
`Autokey`. For a `_GenItem` handle, returns a `_GenItem` of the keyed handle, built from the original's fields.
"""
Base.@nospecializeinfer function _draft_autokey(@nospecialize(obj), i::Int)
    gen = obj isa _GenItem
    gen || obj isa IdentifiableAlgo || return Autokey(obj, i)
    p = _itemtype(obj).parameters    # {F, Id, VarAliases, AlgoName, ContextKey, R}
    p[5] == Symbol() || return obj
    func, reconstructor = _ifield(obj, :func), _ifield(obj, :reconstructor)
    key = Symbol(gen ? _value_trait(autokey_basename, p[1]) : autokey_basename(func), :_, i)
    KT = Core.apply_type(IdentifiableAlgo, p[1], p[2], p[3], p[4], key, p[6])
    gen || return KT(func, reconstructor)
    return _GenItem(KT, Expr(:call, KT, func.ex, reconstructor.ex), Any[func, reconstructor])
end

"""
    build_registry(draft) -> NameSpaceRegistry

The registry that `draft` (filled with values) describes: one `RegistryTypeEntry{T, Tuple{entry types...}}` per
entry type, in order, with the draft's multipliers and lookup tables. Builds each type once, with its constructor
called on the values.
"""
Base.@nospecializeinfer function build_registry(draft::RegistryDraft)
    n = length(draft.types)
    typeentries = Vector{Any}(undef, n)
    for i in 1:n
        entries = Tuple(draft.entries[i])
        typeentries[i] = RegistryTypeEntry{draft.types[i], typeof(entries)}(entries, draft.multipliers[i], draft.lookups[i])
    end
    all_entries = Tuple(typeentries)
    return NameSpaceRegistry{typeof(all_entries)}(all_entries)
end

"""
    registry_expr(draft) -> Expr

The code that builds the registry `draft` (filled with `_GenItem`s) describes, the same one `build_registry` builds
from values: the registry's type is written out, its entries are read from the plan, and each entry type's
multipliers and lookup table are built anew on every run (they are changed in place later).
"""
Base.@nospecializeinfer function registry_expr(draft::RegistryDraft)
    n = length(draft.types)
    entry_types = Vector{Any}(undef, n)
    entry_exprs = Vector{Any}(undef, n)
    for i in 1:n
        items = draft.entries[i]
        E = Tuple{Any[_itemtype(x) for x in items]...}
        entry_types[i] = RegistryTypeEntry{draft.types[i], E}
        entry_exprs[i] = Expr(:call, entry_types[i], Expr(:tuple, Any[x.ex for x in items]...),
            Expr(:ref, Float64, draft.multipliers[i]...), _lookup_expr(draft.lookups[i]))
    end
    return Expr(:call, NameSpaceRegistry{Tuple{entry_types...}}, Expr(:tuple, entry_exprs...))
end

"""The code that builds the lookup table `lookup` of a draft on types: its fixed keys as constants, plus the keys read at run time."""
Base.@nospecializeinfer function _lookup_expr(lookup::Dict{LookupKey,Int})
    fixed_keys, fixed_idxs = LookupKey[], Int[]
    runtime = Any[]
    for (k, i) in lookup
        if k.key isa _RuntimeKey
            push!(runtime, Expr(:call, setindex!, :d, i, Expr(:call, dynamic_lookup_key, k.key.ex)))
        else
            push!(fixed_keys, k); push!(fixed_idxs, i)
        end
    end
    filled = Expr(:call, _lookup_table, Tuple(fixed_keys), Tuple(fixed_idxs))
    isempty(runtime) && return filled
    return Expr(:let, Expr(:(=), :d, filled), Expr(:block, runtime..., :d))
end

"""A new lookup table with `keys[i] => idxs[i]`."""
Base.@nospecializeinfer function _lookup_table(@nospecialize(keys::Tuple), @nospecialize(idxs::Tuple))
    d = Dict{LookupKey,Int}()
    sizehint!(d, length(keys))
    for i in 1:length(keys)
        d[getfield(keys, i)::LookupKey] = getfield(idxs, i)::Int
    end
    return d
end

########################

function scale_multipliers!(reg::NameSpaceRegistry{T}, factor::Number) where {T}
    map(entry -> scale_multipliers!(entry, factor), getentries(reg))
    reg
end

inherit(reg::NameSpaceRegistry, other...; multipliers = repeat([1.], length(other))) = inherit(inherit(reg, other[1], multipliers[1]), other[2:end]...; multipliers = multipliers[2:end])
"""
One registry inherits from another, scaling the multipliers by the given factor
    The multiplier is usually the multiplier of a LoopAlgorithm in it's parent LoopAlgorithm
"""
function inherit(registry1::NameSpaceRegistry, registry2::NameSpaceRegistry, multiplier = 1.)
    entries2 = deepcopy(getentries(registry2)) # Deepcopy in order to not change multipliers of original registry
    scale_multipliers!.(entries2, multiplier)
    @DebugMode "Reg1: $registry1 inheriting entries: $entries2"

    

    for entry in entries2
        for (identifiable, mult) in entry
            @DebugMode "Inheriting identifiable: $identifiable with multiplier: $mult"
            registry1, identifiable = add(registry1, identifiable, mult)
        end
    end
    return registry1
end
inherit(e1::NameSpaceRegistry; kwargs...) = e1

##########################
##### UPDATING NAMES #####
##########################



########################
    ### ACCESSORS ###
########################   
@inline function _get_by_matcher(matcher, entries) 
    if isempty(entries)
        error("Matcher $matcher not found in registry entries: $entries")
    end
    head = gethead(entries)
    headmatcher = match_by(head)
    if headmatcher == matcher
        return head
    else
        tail = gettail(entries)
        return _get_by_matcher(matcher, tail)
    end
end
@inline function get_by_matcher(reg::NameSpaceRegistry, matcher)
    all_entries = all_algos(reg)
    return _get_by_matcher(matcher, all_entries)
end

"""
Return all registered entries whose algorithm type is a subtype of `T`.

The result preserves registry entries, so algorithms are usually returned as
their keyed `IdentifiableAlgo` wrappers. For wrappers, matching uses the wrapped
algorithm type rather than the wrapper type.
"""
@inline function Base.findall(::Type{T}, reg::NameSpaceRegistry) where {T}
    return flat_collect_broadcast(entry -> findall(T, entry), getentries(reg))
end

"""
Get entries for an obj
"""
function get_type_entries(reg::NameSpaceRegistry, obj)
    assigned_t = assign_entrytype(obj)
    idx = find_typeidx(reg, assigned_t)
    if isnothing(idx)
        error("Unknown algo/type referenced in registry lookup, for registry: $reg.\n" *
              "Requested type: $assigned_t\n" *
              "Requested value: $obj\n" *
              "Available entry types: $(entrytypes_iterator(reg))\n" *
              "If this came from a Share or Route, the referenced algo/type is not registered." )
    end
    return getentries(reg)[idx]
end

# IN GENERATED FUNCTIONS
# @generated function get_type_entries(reg::NameSpaceRegistry, typ::Union{T, Type{T}}) where {T}


#########################
### Lookup Utilities ###
#########################

"""
Gets the location in the corresponding type dynamically
"""
function dynamic_lookup(reg::NameSpaceRegistry, val) 
    entries = get_type_entries(reg, val)
    return dynamic_lookup(entries, val)
end

function dynamic_get(reg::NameSpaceRegistry, val)
    entries = get_type_entries(reg, val)
    return dynamic_get(entries, val)
end

@inline function static_get_match(reg::NameSpaceRegistry, val)
    entries = get_type_entries(reg, val)
    @DebugMode "Static get match for value: $val in entries: $entries"

    idx = static_findfirst_match(entries, val)
    if isnothing(idx)
        return nothing
    end

    return getentries(entries)[idx]
end
#######################
####### FINDING #######
#######################


@inline function static_findfirst_match(reg::NameSpaceRegistry, val)
    entries = get_type_entries(reg, val)
    T = gettype(entries)

    idx = static_findfirst_match(entries, val)
    if isnothing(idx)
        return RegistryLocation(T, nothing)
    end
    return RegistryLocation(T, idx)
end

"""
From T, idx
"""
function Base.getindex(reg::NameSpaceRegistry, t::RegistryLocation{T, idx}) where {T, idx}
    if isnothing(T)
        error("No matching entry found for type: (nothing, nothing) in registry")
    end
    type_entries = get_type_entries(reg, T)
    return type_entries[idx]
end


"""
Statically Find the name in the registry
"""
@inline function static_findkey(reg::NameSpaceRegistry, val)
    location = @inline static_findfirst_match(reg, val)
    if isnothing(getidx(location))
        return nothing
    else
        return @inline getkey(reg[location])
    end
end

@inline function Base.in(val, reg::NameSpaceRegistry)
    found_scoped_value = @inline get(reg, val, nothing)
    return !isnothing(found_scoped_value)
end

"""
Look up a registered entry by its assigned symbol key, e.g. `reg[:Fib_1]`.
"""
@inline Base.getindex(reg::NameSpaceRegistry{T}, s::Symbol) where T = _getsymbolindex(reg, Val(s))
"""
Find by key
"""
@inline @generated function _getsymbolindex(reg::NameSpaceRegistry{Ty}, v::Val{key}) where {Ty, key}
    etypes = typeentry_types(reg)
    T = nothing
    found_idx = nothing
    for entry in etypes
        fidx = findkey(entry, key)
        if !isnothing(fidx)
            T = gettype(entry)
            found_idx = fidx
            break
        end
    end
    if isnothing(T)
        error("No entry with key: $key found in registry: $reg")
    end
    loc = RegistryLocation(T, found_idx)
    return :(getindex(reg, $loc))
end
#########################
    ##### GETTERS #####
#########################
"""
Get the static entry from the registry
"""


function static_get(reg::NameSpaceRegistry, v::V) where {V}
    entries = get_type_entries(reg, v)
    idx = findfirst_match(entries, v)
    if isnothing(idx)
        return static_get(entries, v)
    end
    return entries[idx]
end

## TODO : FIX
# function dynamic_get(reg::NameSpaceRegistry, val)
#     entries = get_type_entries(reg, val)
#     loc = dynamic_lookup(entries, val)
#     return getentry(entries, loc...)
# end

function static_get_multiplier(reg::NameSpaceRegistry, val)
    loc = static_findfirst_match(reg, val)
    if isnothing(getidx(loc))
        error("Found other values of type $(gettype(loc)), but no match found for value: $val in registry: $reg")
    end 
    type_entries = get_type_entries(reg, gettype(loc))
    return getmultiplier(type_entries, getidx(loc))
end

function getmultiplier(reg::NameSpaceRegistry, val)
    entries = get_type_entries(reg, val)
    entry_idx = if isstaticallyfindable(val)
        static_findfirst_match(entries, val)
    else
        dynamic_lookup(entries, val)
    end
    if isnothing(entry_idx)
        return 0
    end
    return getmultiplier(entries, entry_idx)
end

"""
Statically Get the name from the registry
"""
@inline function Base.getkey(reg::NameSpaceRegistry, val)
    entry = get(reg, val, nothing)
    if isnothing(entry)
        return nothing
    end
    return getkey(entry)
end


# function dynamic_get(reg::NameSpaceRegistry, v::V) where {V}
#     return dynamic_get(reg, v)
# end

"""
Get the value from the registry
"""
@inline function Base.getindex(reg::NameSpaceRegistry{T}, obj) where {T}
    if isstaticallyfindable(obj)
        return static_get(reg, obj)
    else
        entry = dynamic_get(reg, obj)
        isnothing(entry) && error("No matching entry found for value: $obj in registry: $reg")
        return entry
    end
end

@inline function Base.get(reg::NameSpaceRegistry, obj, default = nothing)
    if isstaticallyfindable(obj)
        try
            return static_get(reg, obj)
        catch e
            return default
        end
    else
        try 
            return dynamic_get(reg, obj)
        catch e
            return default
        end
    end
end

#######################
    ##### NAMES #####
#######################

function all_named_algos(reg::Union{NameSpaceRegistry, Type{<:NameSpaceRegistry}})
    flat_collect_broadcast(all_named_algos, getentries(reg))
end

function all_keys(reg::Union{NameSpaceRegistry, Type{<:NameSpaceRegistry}})
    flat_collect_broadcast(all_keys, getentries(reg))
end

# function find_location_by_name(reg::NameSpaceRegistry, name::Symbol)
#     for (entry_idx, entry) in enumerate(getentries(reg))
#         loc = find_location_by_name(entry, name)
#         if !isnothing(loc)
#             return (entry_idx, loc...)
#         end
#     end
#     return nothing
# end

function replacecontextkeyss(reg::NameSpaceRegistry, changed_names::Dict{Symbol,Symbol})
    newentries = map(entry -> replacecontextkeyss(entry, changed_names), getentries(reg))
    return NameSpaceRegistry{typeof(newentries)}(newentries)
end
    

########################
##### PREPARING ########
########################
"""
Return all named objects
    First AlgoStates, then rest
"""
function all_algos(reg::NameSpaceRegistry)
    return flat_collect_broadcast(getentries, getentries(reg))
end
##########################
    ##### ITERATING #####
##########################

"""
Iterator for NameSpaceRegistry
"""
function Base.iterate(reg::NameSpaceRegistry, state = 1)
    if state > length(getentries(reg))
        return nothing
    else
        return (reg[state], state + 1)
    end
end

function all_entries(reg::NameSpaceRegistry)
    typeentries = getentries(reg)
    return flat_collect_broadcast(getentries, typeentries)
end

########################
  ##### SHOW #####
########################

function Base.show(io::IO, reg::NameSpaceRegistry)
    types = entrytypes_iterator(reg)
    println(io, "NameSpaceRegistry with types: ", types)
    if isempty(getentries(reg))
        print(io, "  (empty)")
        return
    end
    limit = get(io, :limit, false)
    for (idx, entry) in enumerate(getentries(reg))
        entry_str = repr(entry; context = IOContext(io, :limit => limit))
        lines = split(entry_str, '\n')
        for (line_idx, line) in enumerate(lines)
            if line_idx == 1
                print(io, "  [", idx, "] ", line)
            else
                print(io, "\n  ", line)
            end
        end
        if idx < length(getentries(reg))
            print(io, "\n")
        end
    end
end
