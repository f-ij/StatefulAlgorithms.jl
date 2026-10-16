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
function _apply_redirect_mapping(context::C, ::Val{fromname}, ::Val{toname}, ::Val{sourcevar}, ::Val{targetvar}) where {C<:ProcessContext, fromname, toname, sourcevar, targetvar}
    _check_redirect_endpoint(context, Val(fromname), Val(sourcevar), "source")
    _check_redirect_endpoint(context, Val(toname), Val(targetvar), "target")

    marker = RedirectedVar(VarLocation{:state}(fromname, sourcevar))
    patch = NamedTuple{(toname,)}((NamedTuple{(targetvar,)}((marker,)),))
    return @inline merge_into_subcontexts(context, patch)
end

"""Materialize one resolved redirect option into the persistent context."""
function _apply_resolved_redirect(context::C, redirect::R) where {C<:ProcessContext, R<:Redirect}
    fromname = from_match_by(redirect)
    toname = to_match_by(redirect)
    sourcevars = source_fieldnames(redirect)
    targetvars = getaliases(redirect)
    for i in eachindex(sourcevars)
        context = @inline _apply_redirect_mapping(context, Val(fromname), Val(toname), Val(sourcevars[i]), Val(targetvars[i]))
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

@inline apply_redirect_specs(context::C, la::LA) where {C<:ProcessContext, LA<:LoopSpec} =
    @inline apply_redirect_specs(context, getregistry(la), getstoredredirects(la))
