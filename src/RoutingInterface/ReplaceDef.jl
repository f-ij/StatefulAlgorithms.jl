################################################
################ REPLACEMENTS ##################
################################################

"""
Replace a target-local variable location with another subcontext's variable.

`Replace(source => target, :value)` is deliberately stronger than `Route`: the
target view resolves `:value` to the source location before checking target-local
state. Reads and returned writes therefore operate on the source storage while
leaving the target's initialized state slot in place.
"""
struct Replace{Fmatch, Tmatch, FT, RFT, varnames, aliases, F, T} <: AbstractWiring
    from::F
    to::T
end

"""
Construct replacement wiring from endpoint references and variable mappings.

The variable syntax matches `Route`: a bare symbol replaces the same target name,
and `:source_name => :target_name` replaces a differently named target local.
Optional transforms behave like route transforms and require a reverse transform
when the replaced variable is written back.
"""
function Replace(
    from_to::Pair,
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

    @assert (!isnothing(transform) || !isnothing(reverse_transform)) ? (length(originalname_or_aliaspairs) == 1) : true "Transform-based replacements must have exactly one variable mapping, but got $(originalname_or_aliaspairs)"

    from_ref = _wiring_endpoint_ref(from)
    to_ref = _wiring_endpoint_ref(to)
    return Replace{
        _wiring_endpoint_match(from),
        _wiring_endpoint_match(to),
        transform,
        reverse_transform,
        varnames,
        aliases,
        typeof(from_ref),
        typeof(to_ref),
    }(from_ref, to_ref)
end

"""Construct a resolved replacement from its type parameters."""
function Replace{Fmatch, Tmatch, FT, RFT, varnames, aliases, Nothing, Nothing}() where {Fmatch, Tmatch, FT, RFT, varnames, aliases}
    _assert_resolved_endpoint(Fmatch, "Replace origin")
    _assert_resolved_endpoint(Tmatch, "Replace target")
    return Replace{Fmatch, Tmatch, FT, RFT, varnames, aliases, Nothing, Nothing}(nothing, nothing)
end

"""Resolve replacement endpoints against a registry and return target-keyed wiring."""
function resolve_wiring(reg::NameSpaceRegistry, r::R) where {R<:Replace}
    fromname = _resolve_wiring_endpoint(reg, from_match_by(r), getfrom(r), "origin")
    toname = _resolve_wiring_endpoint(reg, to_match_by(r), getto(r), "target")
    resolved = Replace{fromname, toname, gettransform(r), getreverse_transform(r), getvarnames(r), getaliases(r), Nothing, Nothing}()
    return toname => resolved
end

"""Update unresolved replacement endpoints against a parent registry."""
function update_keys(r::R, reg::NameSpaceRegistry) where {R<:Replace}
    isresolved(r) && return r
    newfrom = _update_wiring_endpoint(getfrom(r), from_match_by(r), reg)
    newto = _update_wiring_endpoint(getto(r), to_match_by(r), reg)
    varnames = getvarnames(r)
    aliases = getaliases(r)
    mappings = ntuple(i -> varnames[i] == aliases[i] ? varnames[i] : (varnames[i] => aliases[i]), length(varnames))
    return Replace(newfrom => newto, mappings...; transform = gettransform(r), reverse_transform = getreverse_transform(r))
end
