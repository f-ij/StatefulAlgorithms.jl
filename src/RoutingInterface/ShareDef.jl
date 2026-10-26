################################################
##################  SHARES  ####################
################################################

"""
Share a whole context namespace from one endpoint to another.

The first two type parameters are unresolved endpoint identities or resolved
context-name symbols. Resolved shares store `nothing` in both endpoint fields.
"""
struct Share{FirstMatch, SecondMatch, directional, A1, A2} <: AbstractWiring
    a1::A1
    a2::A2
end

"""
Construct namespace-sharing wiring between two endpoints.

Endpoint symbols are treated as already-resolved context names. Other endpoints
are retained until registry resolution.
"""
Base.@nospecializeinfer function Share(@nospecialize(algo1), @nospecialize(algo2); directional::Bool = false)
    a1 = scref_object(algo1)
    a2 = scref_object(algo2)

    # Like routes, raw shares keep endpoint refs only until resolution. Symbol
    # endpoints are already names and therefore have `Nothing` value fields.
    # `new_instance`: a share of a held `Unique` handle is a new type for every uuid.
    return new_instance(Share{
        scref_match(algo1),
        scref_match(algo2),
        directional,
        typeof(a1),
        typeof(a2),
    }, a1, a2)
end

# The endpoint matchers (parameters 1, 2) are those of the endpoint fields `a1`, `a2` (`list_field_derived_params`).
list_field_derived_params(::Type{<:Share}) = ((1, 1, scref_match), (2, 2, scref_match))

"""Construct a resolved share from its type parameters."""
function Share{FirstMatch, SecondMatch, directional, Nothing, Nothing}() where {FirstMatch, SecondMatch, directional}
    _assert_resolved_endpoint(FirstMatch, "Share source namespace")
    _assert_resolved_endpoint(SecondMatch, "Share target namespace")
    return Share{FirstMatch, SecondMatch, directional, Nothing, Nothing}(nothing, nothing)
end
