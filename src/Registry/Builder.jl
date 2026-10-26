#=
Collects a plan's algorithms into a registry: `add!` puts one algorithm in (its entry type, its key, its multiplier,
or the one already there when it is the same algorithm), and `registry(builder)` builds the registry from them at the
end, following the rules in Interfaces.jl.

A `RegistryBuilder` is plain vectors, the same type for every plan, so adding does not compile anything per plan: a
`NameSpaceRegistry`'s type names every algorithm's type, and adding to it one by one would compile once per add.

The same code runs while the generated `build_registry_and_key_plan` is generated, on the plan's type: `add!` then gets
`GeneratedValue`s (GeneratedValues.jl) instead of algorithms, decides everything from their types (a step that needs
the values, such as a merge, throws `NeedsValues`), and GeneratedCode/Registry/Expressions.jl writes the code that
builds the registry. The lookup key of a `Unique` handle needs its uuid, a value, so there it is a `RuntimeLookupKey`, filled
in by the generated code.
=#

"""
    RuntimeLookupKey(id, handle_expr)

Stands in for the lookup key of a `Unique` handle while the walk works on the plan's type: that key comes from the
uuid in the handle's `matcher` value (`dynamic_lookup_key`), which only exists at run time; `handle_expr` is the
expression in the generated function that gives the handle. Equal for the same id `id` (the handle's
`UniquePlanId{k}` type).
"""
struct RuntimeLookupKey
    id::Any
    handle_expr::Any
end
Base.isequal(a::RuntimeLookupKey, b::RuntimeLookupKey) = isequal(a.id, b.id)
Base.hash(a::RuntimeLookupKey, h::UInt) = hash(a.id, hash(RuntimeLookupKey, h))

"""The keys of a lookup table in the walk on types: a registry entry's (`LookupKey`), plus those only known at run time."""
const TypeWalkLookupKey = Union{LookupKey,RuntimeLookupKey}

"""
    TypeEntryBuilder{M, K}(type)

One entry type of a `RegistryBuilder{M, K}`: the entry type `type` (`Lin`), its keyed algorithms in order, their
multipliers (`M`), the runtime lookup table (`K` => index), and each algorithm's matcher once it has been computed
(`entry_matcher`). In the walk on values `M` is `Float64` and `K` is `LookupKey`, as in the registry entry it becomes;
in the walk on types `M` is `Any` (multipliers are expressions, `multiply_multipliers`) and `K` is `TypeWalkLookupKey`.
"""
struct TypeEntryBuilder{M, K}
    type::Any
    algos::Vector{Any}
    multipliers::Vector{M}
    lookup::Dict{K,Int}
    matchers::Vector{Any}
end
TypeEntryBuilder{M, K}(@nospecialize(type)) where {M, K} = TypeEntryBuilder{M, K}(type, Any[], M[], Dict{K,Int}(), Any[])

struct MatcherNotComputed end   # an entry whose matcher is not computed yet

"""
    RegistryBuilder()
    RegistryBuilder(registry)
    RegistryBuilder{Any, TypeWalkLookupKey}()

A registry under construction, as plain values: its entry types in registry order (`TypeEntryBuilder`s). Empty, or
holding what `registry` (a `NameSpaceRegistry`) holds. Fill it with `add!`; `registry(builder)` gives the registry.
`M` and `K` are the types of its multipliers and lookup keys (`TypeEntryBuilder`): `Float64` and `LookupKey` (the
default) for the walk on values, `Any` and `TypeWalkLookupKey` for the walk on types.
"""
struct RegistryBuilder{M, K}
    entries::Vector{TypeEntryBuilder{M, K}}
end
RegistryBuilder{M, K}() where {M, K} = RegistryBuilder{M, K}(TypeEntryBuilder{M, K}[])
RegistryBuilder() = RegistryBuilder{Float64, LookupKey}()
function RegistryBuilder(reg::NameSpaceRegistry)
    b = RegistryBuilder()
    for rte in getentries(reg)
        algos = Any[getalgos(rte)...]
        push!(b.entries, TypeEntryBuilder{Float64, LookupKey}(getentrytype(rte), algos, copy(getmultipliers(rte)), copy(getdynamiclookup(rte)),
            Any[MatcherNotComputed() for _ in algos]))
    end
    return b
end

###############################################################################
# Adding
###############################################################################

"""
    add!(builder, algo, multiplier) -> keyed algo

Adds `algo` with `multiplier` (how often it runs per root step) to `builder` and returns it as the registry stores it:
keyed (`Lin_1`), or, when it is the same algorithm as one already there (`added_matcher`, `same_algorithm`), that one,
whose multiplier then grows by `multiplier`. Where it goes and under which key is decided by the rules in
Interfaces.jl.

`algo` can be a `GeneratedValue`: it must then be a handle (`IdentifiableAlgo`), whose type decides everything.
"""
Base.@nospecializeinfer function add!(b::RegistryBuilder, @nospecialize(algo), @nospecialize(multiplier))
    T = read_type(algo)
    T <: NameSpaceRegistry && error("Cannot add a NameSpaceRegistry to another NameSpaceRegistry")
    T === Nothing && error("Trying to add `nothing` to a registry")
    algo isa GeneratedValue && !(isconcretetype(T) && T <: IdentifiableAlgo) && throw(NeedsValues())
    entry = find_or_add_entry!(b, assign_entrytype(algo isa GeneratedValue ? T : algo))
    idx = find_same(entry, algo)
    if isnothing(idx)
        keyed = with_autokey(algo, length(entry.algos) + 1)
        push!(entry.algos, keyed)
        push!(entry.multipliers, multiplier)
        push!(entry.matchers, MatcherNotComputed())
        entry.lookup[lookup_key(keyed)] = length(entry.algos)
        return keyed
    end
    add_again!(entry, idx, algo)
    entry.multipliers[idx] = add_multipliers(entry.multipliers[idx], multiplier)
    return entry.algos[idx]
end

"""
    find_or_add_entry!(builder, E) -> TypeEntryBuilder

The entry of `builder` that algorithms of entry type `E` go into: the first whose type `E` is a subtype of, else a new
one, put first or last (`entrytype_goes_first`).
"""
Base.@nospecializeinfer function find_or_add_entry!(b::RegistryBuilder{M, K}, @nospecialize(E)) where {M, K}
    for entry in b.entries
        E <: entry.type && return entry
    end
    entry = TypeEntryBuilder{M, K}(E)
    entrytype_goes_first(E) ? pushfirst!(b.entries, entry) : push!(b.entries, entry)
    return entry
end

"""
    find_same(entry, algo) -> index or nothing

The index of the algorithm in `entry` that `algo` is the same algorithm as, or `nothing`: compared by matchers
(`added_matcher`, `entry_matcher`, `same_algorithm`), or, for a value that is not `isbits` (found by its identity), by
its runtime lookup key.
"""
Base.@nospecializeinfer function find_same(entry::TypeEntryBuilder, @nospecialize(algo))
    if !(algo isa GeneratedValue)
        isstaticallyfindable(algo) || return get(entry.lookup, dynamic_lookup_key(algo), nothing)
    end
    added = added_matcher(algo isa GeneratedValue ? algo.valuetype : algo)
    for i in eachindex(entry.algos)
        entry.matchers[i] isa MatcherNotComputed && (entry.matchers[i] = entry_matcher(read_type(entry.algos[i])))
        same_algorithm(added, entry.matchers[i]) && return i
    end
    return nothing
end

"""
    add_again!(entry, idx, algo)

Updates the algorithm at `idx` of `entry` for `algo`, the same algorithm added again: a key given to `algo` replaces an
automatic one (`is_autokey`), two given keys must agree, and mergeable algorithms are merged (`merges_into`).
"""
Base.@nospecializeinfer function add_again!(entry::TypeEntryBuilder, idx::Int, @nospecialize(algo))
    if has_autokey(entry.algos[idx]) && has_key(algo)
        replace_algo!(entry, idx, algo)
    end
    if has_given_key(entry.algos[idx]) && has_given_key(algo)
        @assert key_of(entry.algos[idx]) == key_of(algo) "Trying to add an entry with name $(key_of(algo)) but an entry with the same type already exists with name $(key_of(entry.algos[idx]))"
    end
    if merges_into(read_type(entry.algos[idx]), read_type(algo))
        # A merge combines the values; from the types it is only known that one happens.
        algo isa GeneratedValue && throw(NeedsValues())
        replace_algo!(entry, idx, merge(entry.algos[idx], algo))
    end
    return nothing
end

"""Puts `new` at `idx` in `entry`, moving the lookup key from the old algorithm to `new` and forgetting its matcher."""
Base.@nospecializeinfer function replace_algo!(entry::TypeEntryBuilder, idx::Int, @nospecialize(new))
    delete!(entry.lookup, lookup_key(entry.algos[idx]))
    entry.lookup[lookup_key(new)] = idx
    entry.algos[idx] = new
    entry.matchers[idx] = MatcherNotComputed()
    return nothing
end

"""
    with_autokey(algo, i) -> keyed algo

`algo` with the automatic key of the `i`-th algorithm of its entry type (`autokey`), or unchanged if it has a key.
For a handle the key is set on its type, as a value (nothing is compiled per handle type and index); another value is
keyed by `Autokey`. For a `GeneratedValue` handle, returns a `GeneratedValue` of the keyed handle, built from its fields
(`build_from_parts`).
"""
Base.@nospecializeinfer function with_autokey(@nospecialize(algo), i::Int)
    algo isa GeneratedValue || algo isa IdentifiableAlgo || return Autokey(algo, i)
    p = read_type(algo).parameters    # {F, Id, VarAliases, AlgoName, ContextKey, M}
    p[5] == Symbol() || return algo
    KT = Core.apply_type(IdentifiableAlgo, p[1], p[2], p[3], p[4], autokey(p[1], i), p[6])
    func, matcher = read_field(algo, :func), read_field(algo, :matcher)
    algo isa GeneratedValue || return KT(func, matcher)
    return build_from_parts(KT, Any[func, matcher])
end

# Keys of an algorithm: of the value, or, for a `GeneratedValue` (always a handle), from its type.
"""The key of the algorithm `x` (`getkey`)."""
key_of(@nospecialize(x)) = x isa GeneratedValue ? getkey(x.valuetype) : getkey(x)
"""Whether the algorithm `x` has a key (`haskey`)."""
has_key(@nospecialize(x)) = x isa GeneratedValue ? getkey(x.valuetype) != Symbol() : haskey(x)
"""Whether the algorithm `x` has an automatic key (`hasautokey`, `is_autokey`)."""
has_autokey(@nospecialize(x)) = x isa GeneratedValue ? is_autokey(algotype(x.valuetype), getkey(x.valuetype)) : hasautokey(x)
"""Whether the algorithm `x` has a key given to it, not an automatic one."""
has_given_key(@nospecialize(x)) = has_key(x) && !has_autokey(x)

"""
    lookup_key(algo) -> LookupKey or RuntimeLookupKey

The key of `algo` in its entry's runtime lookup table (`dynamic_lookup_key`). For a `GeneratedValue`, worked out from its
type, as `dynamic_lookup_key` does for a value; for a handle that keeps its matcher as data (`keeps_matcher_data`), a
`RuntimeLookupKey`.
"""
Base.@nospecializeinfer function lookup_key(@nospecialize(algo))
    algo isa GeneratedValue || return dynamic_lookup_key(algo)
    T = algo.valuetype
    keeps_matcher_data(T) && return RuntimeLookupKey(id(T), algo.value_expr)
    return LookupKey(lower_matcher(entry_matcher(T)))
end

"""
    add(registry, algo, multiplier = 1.0) -> (new registry, keyed algo)

`registry` with `algo` added, and `algo` as the registry stores it; as `add!` on a builder holding `registry`.
"""
Base.@nospecializeinfer function add(reg::NameSpaceRegistry, @nospecialize(algo), @nospecialize(multiplier = 1.0))
    b = RegistryBuilder(reg)
    keyed = add!(b, algo, multiplier)
    return registry(b), keyed
end

###############################################################################
# The registry
###############################################################################

"""
    registry(builder) -> NameSpaceRegistry

The registry `builder` (filled with values) holds: one `RegistryTypeEntry{E, Tuple{algorithm types...}}` per entry
type, in order, with its multipliers and lookup table. Each type is built once, its constructor called on the values.
"""
Base.@nospecializeinfer function registry(b::RegistryBuilder{Float64, LookupKey})
    typeentries = Vector{Any}(undef, length(b.entries))
    for (i, entry) in enumerate(b.entries)
        algos = Tuple(entry.algos)
        typeentries[i] = RegistryTypeEntry{entry.type, typeof(algos)}(algos, entry.multipliers, entry.lookup)
    end
    all_entries = Tuple(typeentries)
    return NameSpaceRegistry{typeof(all_entries)}(all_entries)
end
