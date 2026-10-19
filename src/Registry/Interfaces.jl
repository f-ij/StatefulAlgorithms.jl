#=
The rules that decide a registry's layout.

When a plan is prepared (`resolve`), every algorithm and state in it is added to one registry (`RegistryBuilder`,
`add!`). Where an algorithm goes, under which key, and whether it is the same as one already there is decided by the
functions below, and only by them.

All rules are defined on TYPES: the layout of a plan's registry is worked out from the plan's type when that plan type
is first compiled (`make_registry_recipe`), and the code that builds it is compiled once. These are internal rules of
the package: the package's own types change them by adding methods to the functions marked "Extended by". A method
added or changed after a plan type was compiled (with Revise) is not seen by that plan type's compiled code.
=#

"""
    ask_type_rule(f, T) -> f(x)

The answer of the rule `f` for a value `x` of type `T`, asked with `T` alone: `f` of `T`'s only value when `T` has
just one (a type without fields), else `f(T)`. So a method of such a rule for a type with fields must take the type
(`f(::Union{MyAlgo, Type{<:MyAlgo}})`), as every method in the package does.
"""
ask_type_rule(@nospecialize(f), @nospecialize(T)) = f(Base.issingletontype(T) ? T.instance : T)

###############################################################################
# Entry type: which group of the registry an algorithm goes into
###############################################################################

"""
    registry_entrytype(T) -> Type or nothing

The entry type algorithms of type `T` are registered under, or `nothing` for their own type. Default `nothing`.
Extended by: handles (`IdentifiableAlgo{F}` goes under `F`), `Package`, `ContextExchange`.
"""
registry_entrytype(@nospecialize(T)) = nothing

"""
    assign_entrytype(x) -> Type

The entry type of the registry that `x` (an algorithm, or its type) goes into: `registry_entrytype` of its type, or else
its type, without type parameters (`Lin`, not `Lin{1}`). Algorithms of one entry type are keyed and found among each
other.
"""
@inline function assign_entrytype(x)
    T = x isa Type ? x : typeof(x)
    return Base.typename(something(registry_entrytype(T), T)).wrapper
end

"""
    entrytype_goes_first(E) -> Bool

Whether the entry type `E` is put before every entry type already in the registry when it first appears (else after
them): true for states (`AlgoState`), so a registry lists its states first.
"""
entrytype_goes_first(@nospecialize(E)) = E <: AlgoState

###############################################################################
# The same algorithm: when an added algorithm is one already in the registry
###############################################################################

"""
    added_matcher(x) -> matcher

What an algorithm `x` being added is compared by (with `same_algorithm`) to find it among the algorithms of its entry
type: its `match_by`, and when that is not a matcher itself (`AbstractMatcher`), the `match_by` of that. `x` is the
algorithm, or its type for one known only by its type (for a handle both give its id).
Extended by: `match_by` (Matching.jl), for algorithm types and values.
"""
function added_matcher(@nospecialize(x))
    m = match_by(x)
    return m isa AbstractMatcher ? m : match_by(m)
end

"""
    entry_matcher(T) -> matcher

What an algorithm of type `T` that is already in the registry is compared by: `match_by(T)`.
"""
entry_matcher(@nospecialize(T)) = match_by(T)

"""
    same_algorithm(added, entry) -> Bool

Whether the matcher of an added algorithm (`added_matcher`) and that of an entry (`entry_matcher`) say they are the
same algorithm: `added == entry`, with concrete types (algorithms often match by their type, `Lin{1}`) and normalized
ids equal only if identical.
"""
function same_algorithm(@nospecialize(added), @nospecialize(entry))
    # `==` of two `NormalizedId`s is `===`; calling `==` would compile it once per pair of id types.
    added isa NormalizedId && entry isa NormalizedId && return added === entry
    if added isa DataType && isconcretetype(added) && entry isa DataType && isconcretetype(entry)
        return added === entry
    end
    return added == entry
end

###############################################################################
# Automatic keys: `Lin_1`, `Lin_2`, ...
###############################################################################

# Extended by: `autokey_basename(x)` (Identifiable.jl), the name an automatic key starts with; default the type's name.

"""
    autokey(T, i) -> Symbol

The automatic key of the `i`-th algorithm of type `T` in its entry type: `autokey_basename` of `T`, `_`, `i`
(`Lin_2`). An algorithm added with a key keeps it.
"""
autokey(@nospecialize(T), i::Int) = Symbol(ask_type_rule(autokey_basename, T), :_, i)

"""
    is_autokey(T, key) -> Bool

Whether `key` is an automatic key of an algorithm of type `T` (made by `autokey`), and not a key given to it. A given
key replaces an automatic one when the same algorithm is added again with it.
"""
function is_autokey(@nospecialize(T), key::Symbol)
    key == Symbol() && return false
    return startswith(string(key), string(ask_type_rule(autokey_basename, T), "_"))
end

###############################################################################
# Merging: two entries with the same key that become one
###############################################################################

"""
    registry_allowmerge(T) -> Bool

Whether algorithms of type `T` that are added under the same key are merged into one entry (with `merge`) instead of
being the same entry. Default `false`.
Extended by: `GeneralState` (`@state`), `RuntimeInputState`.
"""
registry_allowmerge(::Type) = false
registry_allowmerge(obj) = registry_allowmerge(obj isa Type ? obj : typeof(obj))

"""
    handles_merge(A, B) -> Bool

Whether handles (`IdentifiableAlgo`) of types `A` and `B` may be merged: both have the same key, and the algorithm type
of either allows merging (`registry_allowmerge`).
"""
function handles_merge(@nospecialize(A::Type{<:IdentifiableAlgo}), @nospecialize(B::Type{<:IdentifiableAlgo}))
    key = getkey(A)
    key != Symbol() && key == getkey(B) || return false
    return ask_type_rule(registry_allowmerge, algotype(A)) || ask_type_rule(registry_allowmerge, algotype(B))
end

"""
    merges_into(E, N) -> Bool

Whether an added algorithm of type `N`, found to be the same algorithm as the entry of type `E`, is merged into it:
both are handles that may be merged (`handles_merge`), and they do not have the same given id (`Unique`): two handles
with one id are the same entry already, also when their values differ (one may come with other diagnostic paths).
"""
function merges_into(@nospecialize(E), @nospecialize(N))
    E <: IdentifiableAlgo && N <: IdentifiableAlgo || return false
    handles_merge(E, N) || return false
    return !(id(E) isa Union{SimpleId, NormalizedId} && id(E) == id(N))
end
