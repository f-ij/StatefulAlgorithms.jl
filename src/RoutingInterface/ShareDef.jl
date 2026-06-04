################################################
##################  SHARES  ####################
################################################

"""
Share a whole context namespace from one endpoint to another.

The first two type parameters are unresolved endpoint identities or resolved
context-name symbols. Resolved shares store `nothing` in both endpoint fields.
"""
struct Share{from, to, directional, A1, A2} <: AbstractWiring
    a1::A1
    a2::A2
end

"""
Construct namespace-sharing wiring between two endpoints.

Endpoint symbols are treated as already-resolved context names. Other endpoints
are retained until registry resolution.
"""
function Share(algo1, algo2; directional::Bool = false)
    a1 = _wiring_endpoint_ref(algo1)
    a2 = _wiring_endpoint_ref(algo2)

    # Like routes, raw shares keep endpoint refs only until resolution. Symbol
    # endpoints are already names and therefore have `Nothing` value fields.
    return Share{
        _wiring_endpoint_match(algo1),
        _wiring_endpoint_match(algo2),
        directional,
        typeof(a1),
        typeof(a2),
    }(a1, a2)
end

"""Construct a resolved share from its type parameters."""
function Share{from, to, directional, Nothing, Nothing}() where {from, to, directional}
    _assert_resolved_endpoint(from, "Share origin")
    _assert_resolved_endpoint(to, "Share target")
    return Share{from, to, directional, Nothing, Nothing}(nothing, nothing)
end
