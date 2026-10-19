################################################
##################  ROUTES  ####################
################################################

"""
Route one or more variables from one subcontext to another.

The first two type parameters are either unresolved endpoint identities or resolved
context-name symbols. `transform` maps backing source values into the target
view, and `reverse_transform` maps returned target-view values back into backing
source values during writeback. Resolved routes have `Nothing` endpoint fields,
allowing `typeof(route)()` to reconstruct the same compile-time route value.
"""
struct Route{Fmatch, Tmatch, FT, RFT, varnames, aliases, F, T} <: AbstractWiring
    from::F
    to::T
end

"""
Construct route wiring from endpoint references and variable mappings.

Endpoint symbols are treated as already-resolved context names. Algorithm and
state references are kept in the value fields until registry resolution.
`transform` maps source values into the target view. `reverse_transform` maps a
returned target-view value back into source storage during merge/writeback.
"""
Base.@nospecializeinfer function Route(
    @nospecialize(from_to::Pair),
    originalname_or_aliaspairs::Union{Symbol, Pair{Symbol, Symbol}, Pair{NTuple{N, Symbol}, Symbol}}...;
    transform = nothing,
    reverse_transform = nothing,
) where {N}
    from, to = from_to
    _assert_route_endpoint(from, "Origin")
    _assert_route_endpoint(to, "Target")

    completed_pairs = ntuple(length(originalname_or_aliaspairs)) do i
        item = originalname_or_aliaspairs[i]
        item isa Symbol ? item => item : item
    end
    varnames = first.(completed_pairs)
    aliases = last.(completed_pairs)

    ((!isnothing(transform) || !isnothing(reverse_transform)) ? (length(originalname_or_aliaspairs) == 1) : true) || construction_assert_error("Transform-based routes must have exactly one variable mapping, but got ", originalname_or_aliaspairs)

    from_ref = scref_object(from)
    to_ref = scref_object(to)
    return Route{
        scref_match(from),
        scref_match(to),
        transform,
        reverse_transform,
        varnames,
        aliases,
        typeof(from_ref),
        typeof(to_ref),
    }(from_ref, to_ref)
end

# The endpoint matchers (parameters 1, 2) are those of the endpoint fields `from`, `to` (Identifiable/UniquePlanIds.jl).
scref_derived_params(::Type{<:Route}) = (1 => 1, 2 => 2)

"""Construct a resolved route from its type parameters."""
function Route{Fmatch, Tmatch, FT, RFT, varnames, aliases, Nothing, Nothing}() where {Fmatch, Tmatch, FT, RFT, varnames, aliases}
    _assert_resolved_endpoint(Fmatch, "Route origin")
    _assert_resolved_endpoint(Tmatch, "Route target")
    return Route{Fmatch, Tmatch, FT, RFT, varnames, aliases, Nothing, Nothing}(nothing, nothing)
end

"""Validate route endpoints accepted by user-facing constructors."""
function _assert_route_endpoint(endpoint, role::String)
    endpoint isa Symbol && return nothing
    endpoint isa ProcessEntity && return nothing
    endpoint isa Type && endpoint <: ProcessEntity && return nothing
    endpoint isa AbstractIdentifiableAlgo && return nothing
    endpoint isa ThisChild && return nothing   # a `From` wire: the child it is attached to
    construction_error(role, " of a Route must be a Symbol, ProcessAlgorithm, AlgoState, or identifiable wrapper. Got: ", endpoint)
end

"""Require resolved wiring endpoints to be context-name symbols."""
function _assert_resolved_endpoint(endpoint, role::String)
    endpoint isa Symbol && return nothing
    construction_error(role, " endpoint must be resolved to a Symbol, got ", endpoint, ".")
end

"""
Resolve route endpoints against a registry and return target-keyed route wiring.

The returned route carries only context-name symbols in its type parameters and
stores no endpoint references.
"""
function resolve_wiring(reg::NameSpaceRegistry, r::R) where {R<:Route}
    fromname = resolve_scref(reg, from_match_by(r), getfrom(r), "origin")
    toname = resolve_scref(reg, to_match_by(r), getto(r), "target")

    # Resolved routes are pure type data: endpoint refs are dropped so
    # `typeof(route)()` reconstructs the same route without runtime lookup.
    resolved = Route{fromname, toname, gettransform(r), getreverse_transform(r), source_fieldnames(r), getaliases(r), Nothing, Nothing}()
    return toname => resolved
end

"""Update unresolved endpoint references against a parent registry."""
function update_keys(r::R, reg::NameSpaceRegistry) where {R<:Route}
    isresolved(r) && return r
    newfrom = update_scref(reg, from_match_by(r), getfrom(r))
    newto = update_scref(reg, to_match_by(r), getto(r))
    varnames = source_fieldnames(r)
    aliases = getaliases(r)
    mappings = ntuple(i -> varnames[i] == aliases[i] ? varnames[i] : (varnames[i] => aliases[i]), length(varnames))
    return Route(newfrom => newto, mappings...; transform = gettransform(r), reverse_transform = getreverse_transform(r))
end

@inline function _route_endpoint_label(x)
    if x isa IdentifiableAlgo
        return IdentifiableAlgo_label(x)
    elseif x isa Type
        return string(nameof(x))
    else
        return summary(x)
    end
end
