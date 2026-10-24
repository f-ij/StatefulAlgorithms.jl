#=
Keys of a registry entry's runtime lookup table (`RegistryTypeEntry.dynamic_lookup`), which finds the algorithms that
are not found by their type (`isstaticallyfindable` is false). A key is the `Symbol` a lowering rule (`lower_matcher`)
gives the algorithm's matcher, wrapped in `LookupKey` to mark where it came from.
=#

"""
    LookupKey(name::Symbol)

A key of a registry entry's runtime lookup table (`RegistryTypeEntry.dynamic_lookup`): the name `lower_matcher` gives an
algorithm's matcher. Equal and hashed by `name`. One concrete type, so the table's methods (`setindex!`, `get`,
`delete!`) are compiled once, not once per key type. Prints as `name`.
"""
struct LookupKey
    name::Symbol
end
Base.print(io::IO, k::LookupKey) = print(io, k.name)
Base.show(io::IO, k::LookupKey) = show(io, k.name)

"""
    lower_matcher(matcher) -> Symbol

The name of `matcher` in a runtime lookup table. A matcher whose data is all in its type (a type, or a singleton such as
`SimpleId{uuid}()`, `ObjectIDMatcher{id}()`, `ValMatcher{v}()`) is named after that type (`lower_type`), so a type and
its instance get the same name. A value with fields of its own (an `isbits` algorithm that matches by value, such as a
`ContextWrite`) is named after the value as printed (`lower_value`). A `UniquePlanId` is named after its uuid only, so
every form of it (held by the user, stripped, numbered) gets the same name. Add a method for a matcher that needs
another name.
"""
Base.@nospecializeinfer lower_matcher(@nospecialize(T::Type)) = lower_type(T)
Base.@nospecializeinfer function lower_matcher(@nospecialize(matcher))
    Base.issingletontype(typeof(matcher)) && return lower_type(typeof(matcher))
    return lower_value(matcher)
end
Base.@nospecializeinfer lower_matcher(id::UniquePlanId) = Symbol(lower_type(UniquePlanId), "_", origin(id))

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

"""
    dynamic_lookup_key(obj) -> LookupKey

The key under which `obj` is stored in a registry's runtime lookup table (`RegistryTypeEntry.dynamic_lookup`): its
matcher (`match_by`) lowered to a name (`lower_matcher`).
"""
dynamic_lookup_key(obj) = LookupKey(lower_matcher(match_by(obj)))
