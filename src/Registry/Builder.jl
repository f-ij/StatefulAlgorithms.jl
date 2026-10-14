#=
Building a registry.

A `RegistryBuilder` collects the algorithms of a registry as plain values: per entry type its keyed algorithms
(`Lin_1`, `Lin_2`, ...), their multipliers and the runtime lookup table. `add!` adds one algorithm, following the rules
in Interfaces.jl; `registry` then creates the `NameSpaceRegistry` once. (Adding to a `NameSpaceRegistry` itself gives a
registry of a new type after every add, which Julia compiles anew each time.)

The builder works in two modes, with the same code:
- on values: `add!` gets the algorithms, and `registry(builder)` builds the registry from them;
- on types: `add!` gets `KnownByType`s (KnownByType.jl), and `registry_code(builder)` is the code that builds the
  registry from the plan at run time. Every decision is then made from the types; a step that needs the values throws
  `NeedsValues`.

The functions take algorithms and types as values (`@nospecialize`), so they are compiled once, not once per plan.
=#

"""
    TypeEntryBuilder(type)

One entry type of a `RegistryBuilder`: the entry type `type` (`Lin`), its keyed algorithms in order, their
multipliers, the runtime lookup table (lookup key => index), and each algorithm's matcher once it has been computed
(`entry_matcher`).
"""
struct TypeEntryBuilder
    type::Any
    algos::Vector{Any}
    multipliers::Vector{Float64}
    lookup::Dict{LookupKey,Int}
    matchers::Vector{Any}
end
TypeEntryBuilder(@nospecialize(type)) = TypeEntryBuilder(type, Any[], Float64[], Dict{LookupKey,Int}(), Any[])

struct MatcherNotComputed end   # an entry whose matcher is not computed yet

"""
    RegistryBuilder()
    RegistryBuilder(registry)

A registry under construction, as plain values: its entry types in registry order (`TypeEntryBuilder`s). Empty, or
holding what `registry` (a `NameSpaceRegistry`) holds. Fill it with `add!`; `registry(builder)` gives the registry.
"""
struct RegistryBuilder
    entries::Vector{TypeEntryBuilder}
end
RegistryBuilder() = RegistryBuilder(TypeEntryBuilder[])
function RegistryBuilder(reg::NameSpaceRegistry)
    b = RegistryBuilder()
    for rte in getentries(reg)
        algos = Any[getentries(rte)...]
        push!(b.entries, TypeEntryBuilder(gettype(rte), algos, copy(getmultipliers(rte)), copy(getdynamiclookup(rte)),
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

`algo` can be a `KnownByType`: it must then be a handle (`IdentifiableAlgo`), whose type decides everything.
"""
Base.@nospecializeinfer function add!(b::RegistryBuilder, @nospecialize(algo), @nospecialize(multiplier))
    T = type_of(algo)
    T <: NameSpaceRegistry && error("Cannot add a NameSpaceRegistry to another NameSpaceRegistry")
    T === Nothing && error("Trying to add `nothing` to a registry")
    algo isa KnownByType && !(isconcretetype(T) && T <: IdentifiableAlgo) && throw(NeedsValues())
    entry = entry_for!(b, assign_entrytype(algo isa KnownByType ? T : algo, ask_rule))
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
    entry.multipliers[idx] += multiplier
    return entry.algos[idx]
end

"""
    entry_for!(builder, E) -> TypeEntryBuilder

The entry of `builder` that algorithms of entry type `E` go into: the first whose type `E` is a subtype of, else a new
one, put first or last (`entrytype_goes_first`).
"""
Base.@nospecializeinfer function entry_for!(b::RegistryBuilder, @nospecialize(E))
    for entry in b.entries
        E <: entry.type && return entry
    end
    entry = TypeEntryBuilder(E)
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
    if !(algo isa KnownByType)
        isstaticallyfindable(algo) || return get(entry.lookup, dynamic_lookup_key(algo), nothing)
    end
    added = added_matcher(algo isa KnownByType ? algo.type : algo)
    for i in eachindex(entry.algos)
        entry.matchers[i] isa MatcherNotComputed && (entry.matchers[i] = entry_matcher(type_of(entry.algos[i])))
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
    if merges_into(type_of(entry.algos[idx]), type_of(algo))
        # A merge combines the values; from the types it is only known that one happens.
        algo isa KnownByType && throw(NeedsValues())
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
keyed by `Autokey`. For a `KnownByType` handle, returns a `KnownByType` of the keyed handle, built from its fields.
"""
Base.@nospecializeinfer function with_autokey(@nospecialize(algo), i::Int)
    algo isa KnownByType || algo isa IdentifiableAlgo || return Autokey(algo, i)
    p = type_of(algo).parameters    # {F, Id, VarAliases, AlgoName, ContextKey, R}
    p[5] == Symbol() || return algo
    KT = Core.apply_type(IdentifiableAlgo, p[1], p[2], p[3], p[4], autokey(p[1], i), p[6])
    func, reconstructor = field_of(algo, :func), field_of(algo, :reconstructor)
    algo isa KnownByType || return KT(func, reconstructor)
    return KnownByType(KT, Expr(:call, KT, func.expr, reconstructor.expr), Any[func, reconstructor])
end

# The key of an algorithm, of the value or, for a `KnownByType` (a handle), from its type.
key_of(@nospecialize(x)) = x isa KnownByType ? getkey(x.type) : getkey(x)
has_key(@nospecialize(x)) = x isa KnownByType ? getkey(x.type) != Symbol() : haskey(x)
has_autokey(@nospecialize(x)) = x isa KnownByType ? is_autokey(algotype(x.type), getkey(x.type)) : hasautokey(x)
has_given_key(@nospecialize(x)) = has_key(x) && !has_autokey(x)

"""
    RuntimeLookupKey(id, expr)

A runtime lookup key known only at run time, while a layout is worked out from types: the key of a normalized handle
comes from its `reconstructor` value (`dynamic_lookup_key`), which `expr` reads. Equal for the same normalized id `id`.
"""
struct RuntimeLookupKey
    id::Any
    expr::Any
end
Base.isequal(a::RuntimeLookupKey, b::RuntimeLookupKey) = isequal(a.id, b.id)
Base.hash(a::RuntimeLookupKey, h::UInt) = hash(a.id, hash(RuntimeLookupKey, h))

"""
    lookup_key(algo) -> LookupKey

The key of `algo` in its entry's runtime lookup table (`dynamic_lookup_key`). For a `KnownByType`, worked out from its
type, as `dynamic_lookup_key` does for a value; for a normalized handle (`IdReconstructor`), a `RuntimeLookupKey`.
"""
Base.@nospecializeinfer function lookup_key(@nospecialize(algo))
    algo isa KnownByType || return dynamic_lookup_key(algo)
    T = algo.type
    T.parameters[6] <: IdReconstructor && return LookupKey(RuntimeLookupKey(id(T), algo.expr))
    return LookupKey(_lowered_matcher(entry_matcher(T)))
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
Base.@nospecializeinfer function registry(b::RegistryBuilder)
    typeentries = Vector{Any}(undef, length(b.entries))
    for (i, entry) in enumerate(b.entries)
        algos = Tuple(entry.algos)
        typeentries[i] = RegistryTypeEntry{entry.type, typeof(algos)}(algos, entry.multipliers, entry.lookup)
    end
    all_entries = Tuple(typeentries)
    return NameSpaceRegistry{typeof(all_entries)}(all_entries)
end

"""
    registry_code(builder) -> Expr

The code that builds the registry `builder` (filled with `KnownByType`s) holds, the same one `registry` builds from
values: the registry's type is written out, its algorithms are read from the plan, and each entry type's multipliers
and lookup table are created anew on every run (they are changed in place later).
"""
Base.@nospecializeinfer function registry_code(b::RegistryBuilder)
    n = length(b.entries)
    entry_types = Vector{Any}(undef, n)
    entry_exprs = Vector{Any}(undef, n)
    for (i, entry) in enumerate(b.entries)
        E = Tuple{Any[type_of(x) for x in entry.algos]...}
        entry_types[i] = RegistryTypeEntry{entry.type, E}
        entry_exprs[i] = Expr(:call, entry_types[i], Expr(:tuple, Any[x.expr for x in entry.algos]...),
            Expr(:ref, Float64, entry.multipliers...), lookup_table_code(entry.lookup))
    end
    return Expr(:call, NameSpaceRegistry{Tuple{entry_types...}}, Expr(:tuple, entry_exprs...))
end

"""The code that creates the lookup table `lookup` of a builder on types: its fixed keys as constants, plus the keys read at run time."""
Base.@nospecializeinfer function lookup_table_code(lookup::Dict{LookupKey,Int})
    fixed_keys, fixed_idxs = LookupKey[], Int[]
    runtime = Any[]
    for (k, i) in lookup
        if k.key isa RuntimeLookupKey
            push!(runtime, Expr(:call, setindex!, :d, i, Expr(:call, dynamic_lookup_key, k.key.expr)))
        else
            push!(fixed_keys, k); push!(fixed_idxs, i)
        end
    end
    filled = Expr(:call, lookup_table, Tuple(fixed_keys), Tuple(fixed_idxs))
    isempty(runtime) && return filled
    return Expr(:let, Expr(:(=), :d, filled), Expr(:block, runtime..., :d))
end

"""A new lookup table with `keys[i] => idxs[i]`."""
Base.@nospecializeinfer function lookup_table(@nospecialize(keys::Tuple), @nospecialize(idxs::Tuple))
    d = Dict{LookupKey,Int}()
    sizehint!(d, length(keys))
    for i in 1:length(keys)
        d[getfield(keys, i)::LookupKey] = getfield(idxs, i)::Int
    end
    return d
end
