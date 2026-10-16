################################################
################ REDIRECTS #####################
################################################

"""
This file defines `Redirect`, the constructor-time redirect declaration.

`Redirect` is not the value stored in a context. It is a `RootOption`: it can be
declared in any plan, and its effect is on the whole run. It records which target
field should be redirected after initialization. During
materialization, `Redirect` resolves its endpoints and writes a `RedirectedVar`
marker into the target context field.
"""

"""
    Redirect(source => target, :name)
    Redirect(source => target, :source_name => :target_name)

Option (a `RootOption`) that marks a target context field as backed by a source
context field. `Redirect` is not plan wiring; `resolve` collects it from every
plan, and it is materialized into the initialized persistent context as a
`RedirectedVar`.
"""
struct Redirect{Fmatch, Tmatch, varnames, aliases, F, T} <: RootOption
    from::F
    to::T
end

function Redirect(
    from_to::Pair,
    originalname_or_aliaspairs::Union{Symbol, Pair{Symbol, Symbol}}...,
)
    from, to = from_to
    _assert_route_endpoint(from, "Origin")
    _assert_route_endpoint(to, "Target")
    isempty(originalname_or_aliaspairs) && error("Redirect requires at least one variable mapping.")

    completed_pairs = ntuple(length(originalname_or_aliaspairs)) do i
        item = originalname_or_aliaspairs[i]
        item isa Symbol ? item => item : item
    end
    varnames = first.(completed_pairs)
    aliases = last.(completed_pairs)
    from_ref = scref_object(from)
    to_ref = scref_object(to)
    return Redirect{
        scref_match(from),
        scref_match(to),
        varnames,
        aliases,
        typeof(from_ref),
        typeof(to_ref),
    }(from_ref, to_ref)
end

"""Construct a resolved redirect from its type parameters."""
function Redirect{Fmatch, Tmatch, varnames, aliases, Nothing, Nothing}() where {Fmatch, Tmatch, varnames, aliases}
    _assert_resolved_endpoint(Fmatch, "Redirect origin")
    _assert_resolved_endpoint(Tmatch, "Redirect target")
    return Redirect{Fmatch, Tmatch, varnames, aliases, Nothing, Nothing}(nothing, nothing)
end

"""Return the unresolved source endpoint reference stored on a redirect."""
getfrom(r::Redirect) = getfield(r, :from)

"""Return the unresolved target endpoint reference stored on a redirect."""
getto(r::Redirect) = getfield(r, :to)

"""Return source variable names carried by a redirect."""
source_fieldnames(::Union{Redirect{Fmatch, Tmatch, varnames}, Type{<:Redirect{Fmatch, Tmatch, varnames}}}) where {Fmatch, Tmatch, varnames} = varnames

"""Return target variable aliases carried by a redirect."""
getaliases(::Union{Redirect{Fmatch, Tmatch, varnames, aliases}, Type{<:Redirect{Fmatch, Tmatch, varnames, aliases}}}) where {Fmatch, Tmatch, varnames, aliases} = aliases

"""Return the redirect origin matcher identity or resolved origin name."""
from_match_by(::Union{Redirect{Fmatch}, Type{<:Redirect{Fmatch}}}) where {Fmatch} = Fmatch

"""Return the redirect target matcher identity or resolved target name."""
to_match_by(::Union{Redirect{Fmatch, Tmatch}, Type{<:Redirect{Fmatch, Tmatch}}}) where {Fmatch, Tmatch} = Tmatch

"""Return whether a redirect has already been resolved to context-name symbols."""
isresolved(r::Union{Redirect{Fmatch, Tmatch}, Type{<:Redirect{Fmatch, Tmatch}}}) where {Fmatch, Tmatch} =
    Fmatch isa Symbol && Tmatch isa Symbol

"""Resolve redirect endpoints against a registry."""
function resolve_redirect(reg::NameSpaceRegistry, r::R) where {R<:Redirect}
    fromname = resolve_scref(reg, from_match_by(r), getfrom(r), "origin")
    toname = resolve_scref(reg, to_match_by(r), getto(r), "target")
    return Redirect{fromname, toname, source_fieldnames(r), getaliases(r), Nothing, Nothing}()
end

"""Update unresolved endpoint references against a parent registry."""
function update_keys(r::R, reg::NameSpaceRegistry) where {R<:Redirect}
    isresolved(r) && return r
    newfrom = update_scref(reg, from_match_by(r), getfrom(r))
    newto = update_scref(reg, to_match_by(r), getto(r))
    varnames = source_fieldnames(r)
    aliases = getaliases(r)
    mappings = ntuple(i -> varnames[i] == aliases[i] ? varnames[i] : (varnames[i] => aliases[i]), length(varnames))
    return Redirect(newfrom => newto, mappings...)
end
