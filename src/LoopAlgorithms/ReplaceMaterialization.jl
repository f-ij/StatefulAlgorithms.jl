"""
    getstoredreplacements(la)

Return root-level replacement options attached to `la`.
"""
@inline getstoredreplacements(la::LA) where {LA<:LoopSpec} =
    filter_by_type(Replace, getoptions(la))

"""Return one required stored value from a persistent context field."""
function _replacement_context_value(context::C, ::Val{subcontext}, ::Val{name}, role::String) where {C<:ProcessContext, subcontext, name}
    subcontexts = @inline get_subcontexts(context)
    subcontext in keys(subcontexts) || error("Replace $role subcontext `$subcontext` not found. Available subcontexts are $(keys(subcontexts)).")
    data = @inline getdata(getproperty(subcontexts, subcontext))
    name in keys(data) || error("Replace $role variable `$subcontext.$name` not found. Available variables are $(keys(data)).")
    return @inline getproperty(data, name)
end

"""Write one replacement marker into its target persistent context field."""
function _apply_replace_mapping(context::C, ::Val{fromname}, ::Val{toname}, ::Val{sourcevar}, ::Val{targetvar}) where {C<:ProcessContext, fromname, toname, sourcevar, targetvar}
    fromname === toname && sourcevar === targetvar && error("Replace cannot point `$toname.$targetvar` to itself.")
    _replacement_context_value(context, Val(fromname), Val(sourcevar), "source")
    _replacement_context_value(context, Val(toname), Val(targetvar), "target")

    marker = ReplacedVar(VarLocation{:subcontext}(fromname, sourcevar))
    patch = NamedTuple{(toname,)}((NamedTuple{(targetvar,)}((marker,)),))
    return @inline merge_into_subcontexts(context, patch)
end

"""Materialize one resolved replacement option into the persistent context."""
function _apply_resolved_replace(context::C, replacement::R) where {C<:ProcessContext, R<:Replace}
    fromname = from_match_by(replacement)
    toname = to_match_by(replacement)
    sourcevars = getvarnames(replacement)
    targetvars = getaliases(replacement)
    for i in eachindex(sourcevars)
        context = @inline _apply_replace_mapping(context, Val(fromname), Val(toname), Val(sourcevars[i]), Val(targetvars[i]))
    end
    return context
end

"""
    apply_replace_specs(context, registry, replacements)

Resolve and materialize root-level `Replace` options into the initialized
persistent context. Replacement stays out of plan wiring; the only runtime
state change is a `ReplacedVar` marker in each target field.
"""
function apply_replace_specs(context::C, registry::R, replacements::Replacements) where {C<:ProcessContext, R<:NameSpaceRegistry, Replacements<:Tuple}
    for replacement in replacements
        context = @inline _apply_resolved_replace(context, resolve_replacement(registry, replacement))
    end
    return context
end

@inline apply_replace_specs(context::C, la::LA) where {C<:ProcessContext, LA<:LoopSpec} =
    @inline apply_replace_specs(context, getregistry(la), getstoredreplacements(la))
