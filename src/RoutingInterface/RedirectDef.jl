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
    Redirect(source_namespace => target_namespace, :name)
    Redirect(source_namespace => target_namespace, :source_field => :target_field)

Option (a `RootOption`) that marks a target context field as backed by a source
context field. `Redirect` is not plan wiring; `resolve` collects it from every
plan, and it is materialized into the initialized persistent context as a
`RedirectedVar`.
"""
struct Redirect{Smatch, Tmatch, varnames, aliases, S, T} <: RootOption
    source_ref::S
    target_ref::T
end

# Untyped, made with `new_instance`: a redirect from a held `Unique` handle is a new type for every uuid.
Base.@nospecializeinfer function Redirect(
    @nospecialize(namespaces::Pair),
    originalname_or_aliaspairs::Union{Symbol, Pair{Symbol, Symbol}}...,
)
    source_ns, target_ns = namespaces
    _assert_route_endpoint(source_ns, "Source namespace")
    _assert_route_endpoint(target_ns, "Target namespace")
    isempty(originalname_or_aliaspairs) && error("Redirect requires at least one variable mapping.")

    completed_pairs = ntuple(length(originalname_or_aliaspairs)) do i
        item = originalname_or_aliaspairs[i]
        item isa Symbol ? item => item : item
    end
    varnames = first.(completed_pairs)
    aliases = last.(completed_pairs)
    source_ref = scref_object(source_ns)
    target_ref = scref_object(target_ns)
    return new_instance(Redirect{
        scref_match(source_ns),
        scref_match(target_ns),
        varnames,
        aliases,
        typeof(source_ref),
        typeof(target_ref),
    }, source_ref, target_ref)
end

# The endpoint matchers (parameters 1, 2) are those of the endpoint fields `source_ref`, `target_ref` (Identifiable/UniquePlanIds.jl).
scref_derived_params(::Type{<:Redirect}) = (1 => 1, 2 => 2)

"""Construct a resolved redirect from its type parameters."""
function Redirect{Smatch, Tmatch, varnames, aliases, Nothing, Nothing}() where {Smatch, Tmatch, varnames, aliases}
    _assert_resolved_endpoint(Smatch, "Redirect source namespace")
    _assert_resolved_endpoint(Tmatch, "Redirect target namespace")
    return Redirect{Smatch, Tmatch, varnames, aliases, Nothing, Nothing}(nothing, nothing)
end

"""Return the unresolved source-namespace reference stored on a redirect."""
get_source_ref(r::Redirect) = getfield(r, :source_ref)

"""Return the unresolved target-namespace reference stored on a redirect."""
get_target_ref(r::Redirect) = getfield(r, :target_ref)

"""Return the source field names carried by a redirect."""
source_fieldnames(::Union{Redirect{Smatch, Tmatch, varnames}, Type{<:Redirect{Smatch, Tmatch, varnames}}}) where {Smatch, Tmatch, varnames} = varnames

"""Return the target field names (aliases) carried by a redirect."""
getaliases(::Union{Redirect{Smatch, Tmatch, varnames, aliases}, Type{<:Redirect{Smatch, Tmatch, varnames, aliases}}}) where {Smatch, Tmatch, varnames, aliases} = aliases

"""Return the redirect source-namespace matcher identity, or the resolved source namespace."""
source_match_by(::Union{Redirect{Smatch}, Type{<:Redirect{Smatch}}}) where {Smatch} = Smatch

"""Return the redirect target-namespace matcher identity, or the resolved target namespace."""
target_match_by(::Union{Redirect{Smatch, Tmatch}, Type{<:Redirect{Smatch, Tmatch}}}) where {Smatch, Tmatch} = Tmatch

"""Return whether a redirect has already been resolved to context-name symbols."""
isresolved(r::Union{Redirect{Smatch, Tmatch}, Type{<:Redirect{Smatch, Tmatch}}}) where {Smatch, Tmatch} =
    Smatch isa Symbol && Tmatch isa Symbol

"""Resolve redirect endpoints against a registry."""
function resolve_redirect(reg::NameSpaceRegistry, r::R) where {R<:Redirect}
    source_ns = resolve_scref(reg, source_match_by(r), get_source_ref(r), "source namespace")
    target_ns = resolve_scref(reg, target_match_by(r), get_target_ref(r), "target namespace")
    return Redirect{source_ns, target_ns, source_fieldnames(r), getaliases(r), Nothing, Nothing}()
end

"""Update unresolved endpoint references against a parent registry."""
function update_keys(r::R, reg::NameSpaceRegistry) where {R<:Redirect}
    isresolved(r) && return r
    new_source_ns = update_scref(reg, source_match_by(r), get_source_ref(r))
    new_target_ns = update_scref(reg, target_match_by(r), get_target_ref(r))
    varnames = source_fieldnames(r)
    aliases = getaliases(r)
    mappings = ntuple(i -> varnames[i] == aliases[i] ? varnames[i] : (varnames[i] => aliases[i]), length(varnames))
    return Redirect(new_source_ns => new_target_ns, mappings...)
end
