#=
Keys of a registry entry's runtime lookup table (`RegistryTypeEntry.dynamic_lookup`), which finds the algorithms that
are not found by their type (`isstaticallyfindable` is false). `LookupKey(algo)` is the key of an algorithm: its matcher
named by `lower_to_lookupkey`.
=#

"""
    LookupKey(algo)
    LookupKey(name::Symbol)

The key of the algorithm `algo` in a registry entry's runtime lookup table (`RegistryTypeEntry.dynamic_lookup`): its
matcher (`match_by`) named by `lower_to_lookupkey`. The same key when `algo` is stored and when it is looked up, in a
registry built from values and in one built by generated code (which writes `LookupKey(algo)` for an algorithm whose
value it does not know, GeneratedCode/Registry/Expressions.jl). Equal and hashed by `name`. One concrete type, so the
table's methods (`setindex!`, `get`, `delete!`) are compiled once, not once per key type. Prints as `name`.
"""
struct LookupKey
    name::Symbol
    LookupKey(name::Symbol) = new(name)   # inner, so Julia adds no converting `LookupKey(x)`: that is `LookupKey(algo)`
end
Base.@nospecializeinfer LookupKey(@nospecialize(algo)) = LookupKey(lower_to_lookupkey(match_by(algo)))

"""
    known_lookupkey(T) -> LookupKey or nothing

The `LookupKey` of every algorithm of type `T`, when the type decides it: its matcher worked out from the type
(`match_by`) named by `lower_to_lookupkey`. `nothing` for a handle that keeps its matcher as data (a `Unique`
handle's uuid, a merged state's ids: `keeps_matcher_data`), whose key needs the value. The generated registry code holds
a known key as a constant and writes `LookupKey(<the algorithm>)` for the others.
"""
Base.@nospecializeinfer function known_lookupkey(@nospecialize(T::Type))
    keeps_matcher_data(T) && return nothing
    return LookupKey(lower_to_lookupkey(match_by(T)))
end
Base.print(io::IO, k::LookupKey) = print(io, k.name)
Base.show(io::IO, k::LookupKey) = show(io, k.name)

"""
    lower_to_lookupkey(matcher) -> Symbol

The name of `matcher` in a `LookupKey`. A matcher whose data is all in its type (a type, or a singleton such as
`SimpleId{uuid}()`, `ObjectIDMatcher{id}()`, `ValMatcher{v}()`) is named after that type (`lower_type`), so a type and
its instance get the same name. A value with fields of its own (an `isbits` algorithm that matches by value, such as a
`ContextWrite`) is named after the value as printed (`lower_value`). Add a method for a matcher that needs another name.
Extended by: `UniquePlanId` (after its uuid only), Identifiable/UniquePlanId/HookExtensions.jl.
"""
Base.@nospecializeinfer lower_to_lookupkey(@nospecialize(T::Type)) = lower_type(T)
Base.@nospecializeinfer function lower_to_lookupkey(@nospecialize(matcher))
    Base.issingletontype(typeof(matcher)) && return lower_type(typeof(matcher))
    return lower_value(matcher)
end

"""
    lower_type(T) -> Symbol

`T` printed in full as a `Symbol`, e.g. `Symbol("StatefulAlgorithms.SimpleId{Base.UUID(\"9e27…\")}")`. Names are
qualified as seen from `Core`, so the result is the same in every session whatever `Main` has loaded: a key worked out
while precompiling equals the one worked out later (plain `string(T)` drops the module of exported names after `using`).
Printing is slow (tens of µs), so each type's name is kept after the first time (`LOWERED_TYPES`).
"""
Base.@nospecializeinfer function lower_type(@nospecialize(T::Type))
    @lock LOWERED_TYPES_LOCK begin
        name = get(LOWERED_TYPES, T, nothing)
        name isa Symbol && return name
        name = Symbol(sprint(show, T; context = :module => Core))
        LOWERED_TYPES[T] = name
        return name
    end
end
const LOWERED_TYPES = IdDict{Any,Symbol}()   # type => its name (`lower_type`)
const LOWERED_TYPES_LOCK = ReentrantLock()

"""
    lower_value(x) -> Symbol

The value `x` printed as a `Symbol`, names qualified as in `lower_type`.
"""
Base.@nospecializeinfer lower_value(@nospecialize(x)) = Symbol(sprint(show, x; context = :module => Core))

