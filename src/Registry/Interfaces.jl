#=
The rules that decide a registry's layout.

When a plan is prepared (`resolve`), every algorithm and state in it is added to one registry (`RegistryBuilder`,
`add!`). Where an algorithm goes, under which key, and whether it is the same as one already there is decided by the
functions below, and only by them.

All rules are defined on TYPES: the layout of a plan's registry is worked out from the plan's type when that plan type
is first compiled (the generated `build_registry_and_key_plan`), and the code that builds it is compiled once. These are internal rules of
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
Extended by: `RuntimeInputState` (`@input`).
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
both are handles that may be merged (`handles_merge`).
"""
merges_into(@nospecialize(E), @nospecialize(N)) = E <: IdentifiableAlgo && N <: IdentifiableAlgo && handles_merge(E, N)

