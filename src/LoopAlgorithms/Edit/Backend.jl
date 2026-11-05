# Backend of the LoopAlgorithm edit functions in Edit.jl: the unresolved-only guard,
# tuple insert/replace, schedule-entry defaults and normalisation per plan kind, and
# key renaming for algorithms, states, options, shares and routes.

@inline function _ensure_unresolved_for_edit(la::LA) where {LA<:LoopSpec}
    isresolved(la) && error("LoopAlgorithm edit tools currently require an unresolved loop algorithm. Edit the unresolved algorithm first, then call resolve again.")
    return la
end

@inline _edit_entity(x) = x
@inline function _edit_entity(x::Pair)
    @assert x.first isa Symbol "If passing an edit entity as a pair, the first element must be a Symbol key, but got $(x.first)"
    return IdentifiableAlgo(x.second, x.first)
end

@inline function _tuple_insert(t::Tuple, idx::Integer, val)
    @assert 1 <= idx <= length(t) + 1 "Insert index $idx out of bounds for tuple of length $(length(t))"
    return (t[1:(idx - 1)]..., val, t[idx:end]...)
end

@inline function _tuple_replace(t::Tuple, idx::Integer, val)
    @assert 1 <= idx <= length(t) "Replace index $idx out of bounds for tuple of length $(length(t))"
    return tuple_setindex(t, val, idx)
end

@inline _default_schedule_entry(::Routine) = Repeat(1)
@inline _default_schedule_entry(::Union{CompositeAlgorithm, ThreadedCompositeAlgorithm}) = Interval(1)
@inline _default_schedule_entry(la::LoopAlgorithm) = _default_schedule_entry(getplan(la))

@inline _normalize_schedule_entry(::Routine, spec::Lifetime) = spec
@inline _normalize_schedule_entry(::Routine, spec) = Repeat(spec)
@inline _normalize_schedule_entry(::Union{CompositeAlgorithm, ThreadedCompositeAlgorithm}, spec::RunIf) = spec
@inline _normalize_schedule_entry(::Union{CompositeAlgorithm, ThreadedCompositeAlgorithm}, spec::Interval) = spec
@inline _normalize_schedule_entry(::Union{CompositeAlgorithm, ThreadedCompositeAlgorithm}, spec::Real) = Interval(round(Int, spec))
@inline _normalize_schedule_entry(la::LoopAlgorithm, spec) = _normalize_schedule_entry(getplan(la), spec)

@inline _schedule_entries(la::Union{CompositeAlgorithm, Routine, ThreadedCompositeAlgorithm}) = Tuple(getschedule(la))
@inline _schedule_entries(la::LoopAlgorithm) = _schedule_entries(getplan(la))

@inline _collapse_schedule_spec(::Routine, entries::Tuple) = entries
@inline _collapse_schedule_spec(::Union{CompositeAlgorithm, ThreadedCompositeAlgorithm}, entries::Tuple) = entries
@inline _collapse_schedule_spec(la::LoopAlgorithm, entries::Tuple) = _collapse_schedule_spec(getplan(la), entries)

@inline _rename_item(item, replacements::Tuple{Vararg{Pair}}) = replacecontextkeys(item, collect(replacements))
@inline _rename_item(item, replacement::Pair) = replacecontextkeys(item, replacement)
@inline _rename_item(item::LocalPlanOption, replacements::Tuple{Vararg{Pair}}) =
    LocalPlanOption(_rename_item(getfield(item, :owner), replacements), _rename_item(getfield(item, :option), replacements))
@inline _rename_item(item::LocalPlanOption, replacements) =
    LocalPlanOption(_rename_item(getfield(item, :owner), replacements), _rename_item(getfield(item, :option), replacements))

@inline function _rename_item(s::Share, replacements)
    Share(
        _rename_item(get_firstalgo(s), replacements),
        _rename_item(get_secondalgo(s), replacements);
        directional = is_directional(s),
    )
end

@inline function _rename_route(r::Route, replacements)
    varnames = source_fieldnames(r)
    aliases = getaliases(r)
    mappings = ntuple(i -> varnames[i] == aliases[i] ? varnames[i] : (varnames[i] => aliases[i]), length(varnames))
    return Route(
        _rename_item(get_source_ref(r), replacements) => _rename_item(get_target_ref(r), replacements),
        mappings...;
        transform = gettransform(r),
        reverse_transform = getreverse_transform(r),
    )
end

@inline _rename_item(r::Route, replacements) = _rename_route(r, replacements)
@inline _rename_item(r::Route, replacements::Tuple{Vararg{Pair}}) = _rename_route(r, replacements)
