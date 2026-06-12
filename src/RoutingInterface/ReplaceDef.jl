################################################
################ REPLACEMENTS ##################
################################################

"""
This file defines `Replace`, the constructor-time replacement declaration.

`Replace` is not the value stored in a context. It is a root option that records
which target field should be replaced after initialization. During
materialization, `Replace` resolves its endpoints and writes a `ReplacedVar`
marker into the target context field.
"""

"""
    Replace(source => target, :name)
    Replace(source => target, :source_name => :target_name)

Root-level constructor option that marks a target context field as locally
backed by a source context field. `Replace` is not plan wiring; it is
materialized into the initialized persistent context as a `ReplacedVar`.
"""
struct Replace{Fmatch, Tmatch, varnames, aliases, F, T} <: AbstractOption
    from::F
    to::T
end

function Replace(
    from_to::Pair,
    originalname_or_aliaspairs::Union{Symbol, Pair{Symbol, Symbol}}...,
)
    from, to = from_to
    _assert_route_endpoint(from, "Origin")
    _assert_route_endpoint(to, "Target")
    isempty(originalname_or_aliaspairs) && error("Replace requires at least one variable mapping.")

    completed_pairs = ntuple(length(originalname_or_aliaspairs)) do i
        item = originalname_or_aliaspairs[i]
        item isa Symbol ? item => item : item
    end
    varnames = first.(completed_pairs)
    aliases = last.(completed_pairs)
    from_ref = _wiring_endpoint_ref(from)
    to_ref = _wiring_endpoint_ref(to)
    return Replace{
        _wiring_endpoint_match(from),
        _wiring_endpoint_match(to),
        varnames,
        aliases,
        typeof(from_ref),
        typeof(to_ref),
    }(from_ref, to_ref)
end

"""Construct a resolved replacement from its type parameters."""
function Replace{Fmatch, Tmatch, varnames, aliases, Nothing, Nothing}() where {Fmatch, Tmatch, varnames, aliases}
    _assert_resolved_endpoint(Fmatch, "Replace origin")
    _assert_resolved_endpoint(Tmatch, "Replace target")
    return Replace{Fmatch, Tmatch, varnames, aliases, Nothing, Nothing}(nothing, nothing)
end

"""Return the unresolved source endpoint reference stored on a replacement."""
getfrom(r::Replace) = getfield(r, :from)

"""Return the unresolved target endpoint reference stored on a replacement."""
getto(r::Replace) = getfield(r, :to)

"""Return source variable names carried by a replacement."""
getvarnames(::Union{Replace{Fmatch, Tmatch, varnames}, Type{<:Replace{Fmatch, Tmatch, varnames}}}) where {Fmatch, Tmatch, varnames} = varnames

"""Return target variable aliases carried by a replacement."""
getaliases(::Union{Replace{Fmatch, Tmatch, varnames, aliases}, Type{<:Replace{Fmatch, Tmatch, varnames, aliases}}}) where {Fmatch, Tmatch, varnames, aliases} = aliases

"""Return the replacement origin matcher identity or resolved origin name."""
from_match_by(::Union{Replace{Fmatch}, Type{<:Replace{Fmatch}}}) where {Fmatch} = Fmatch

"""Return the replacement target matcher identity or resolved target name."""
to_match_by(::Union{Replace{Fmatch, Tmatch}, Type{<:Replace{Fmatch, Tmatch}}}) where {Fmatch, Tmatch} = Tmatch

"""Return whether a replacement has already been resolved to context-name symbols."""
isresolved(r::Union{Replace{Fmatch, Tmatch}, Type{<:Replace{Fmatch, Tmatch}}}) where {Fmatch, Tmatch} =
    Fmatch isa Symbol && Tmatch isa Symbol

"""Resolve replacement endpoints against a registry."""
function resolve_replacement(reg::NameSpaceRegistry, r::R) where {R<:Replace}
    fromname = _resolve_wiring_endpoint(reg, from_match_by(r), getfrom(r), "origin")
    toname = _resolve_wiring_endpoint(reg, to_match_by(r), getto(r), "target")
    return Replace{fromname, toname, getvarnames(r), getaliases(r), Nothing, Nothing}()
end

"""Update unresolved endpoint references against a parent registry."""
function update_keys(r::R, reg::NameSpaceRegistry) where {R<:Replace}
    isresolved(r) && return r
    newfrom = _update_wiring_endpoint(getfrom(r), from_match_by(r), reg)
    newto = _update_wiring_endpoint(getto(r), to_match_by(r), reg)
    varnames = getvarnames(r)
    aliases = getaliases(r)
    mappings = ntuple(i -> varnames[i] == aliases[i] ? varnames[i] : (varnames[i] => aliases[i]), length(varnames))
    return Replace(newfrom => newto, mappings...)
end
