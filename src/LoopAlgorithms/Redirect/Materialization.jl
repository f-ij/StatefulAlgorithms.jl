"""
    getstoredredirects(la)

Return the `Redirect` options of `la`: on a resolved `LoopAlgorithm`, those collected from its whole plan tree.
"""
@inline getstoredredirects(la::LA) where {LA<:LoopSpec} =
    filter_by_type(Redirect, getoptions(la))

"""Error unless `subcontext.name` exists in the persistent context; `role` ("source"/"target") goes in the message."""
function _check_redirect_endpoint(context::C, ::Val{subcontext}, ::Val{name}, role::String) where {C<:ProcessContext, subcontext, name}
    subcontexts = @inline get_subcontexts(context)
    subcontext in keys(subcontexts) || error("Redirect $role subcontext `$subcontext` not found. Available subcontexts are $(keys(subcontexts)).")
    data = @inline getdata(getproperty(subcontexts, subcontext))
    name in keys(data) || error("Redirect $role variable `$subcontext.$name` not found. Available variables are $(keys(data)).")
    return nothing
end

"""Write one redirect marker into its target persistent context field."""
function _apply_redirect_mapping(context::C, ::Val{source_ns}, ::Val{target_ns}, ::Val{source_field}, ::Val{target_field}) where {C<:ProcessContext, source_ns, target_ns, source_field, target_field}
    _check_redirect_endpoint(context, Val(source_ns), Val(source_field), "source")
    _check_redirect_endpoint(context, Val(target_ns), Val(target_field), "target")

    marker = RedirectedVar(VarLocation{:state}(source_ns, source_field))
    patch = NamedTuple{(target_ns,)}((NamedTuple{(target_field,)}((marker,)),))
    return @inline merge_into_subcontexts(context, patch)
end

"""Materialize one resolved redirect option into the persistent context."""
function _apply_resolved_redirect(context::C, redirect::R) where {C<:ProcessContext, R<:Redirect}
    source_ns = source_match_by(redirect)
    target_ns = target_match_by(redirect)
    source_fields = source_fieldnames(redirect)
    target_fields = getaliases(redirect)
    for i in eachindex(source_fields)
        context = @inline _apply_redirect_mapping(context, Val(source_ns), Val(target_ns), Val(source_fields[i]), Val(target_fields[i]))
    end
    return context
end

"""
    apply_redirect_specs(context, registry, redirects)

Resolve and materialize the collected `Redirect` options into the initialized
persistent context. Redirect stays out of plan wiring; the only runtime
state change is a `RedirectedVar` marker in each target field.
"""
function apply_redirect_specs(context::C, registry::R, redirects::Redirects) where {C<:ProcessContext, R<:NameSpaceRegistry, Redirects<:Tuple}
    for redirect in redirects
        context = @inline _apply_resolved_redirect(context, resolve_redirect(registry, redirect))
    end
    isempty(redirects) || check_redirect_cycles(context)
    return context
end

"""
    apply_redirect_specs(context, la)

Apply the redirects of the resolved `la` to `context` (see the method above) and return the new context. Throws if
`la` is not resolved, since the redirect endpoints are looked up in its registry.
"""
@inline function apply_redirect_specs(context::C, la::LA) where {C<:ProcessContext, LA<:LoopSpec}
    isresolved(la) || error("apply_redirect_specs requires a resolved LoopAlgorithm; call `resolve` first. Got $(typeof(la)).")
    return @inline apply_redirect_specs(context, getregistry(la), getstoredredirects(la))
end
