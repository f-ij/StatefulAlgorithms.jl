export insert, addalgo, addstate, addoption, rename, changeinterval, changeintervals

import Base: rename

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

"""
What a plain number means as a new entry of `la` (`_normalize_schedule_entry`): a repeat (`Val(:repeat)`) in a plan
of repeat entries only, else an interval (`Val(:interval)`).
"""
@inline _entry_kind(plan::Plan) = !isempty(getschedule(plan)) && all(e -> e isa Lifetime, getschedule(plan)) ? Val(:repeat) : Val(:interval)
@inline _entry_kind(::ThreadedCompositeAlgorithm) = Val(:interval)
@inline _entry_kind(la::LoopAlgorithm) = _entry_kind(getplan(la))

"""The entry of a child added without one: `Repeat(1)` in a plan of repeat entries only, else `Interval(1)`."""
@inline _default_schedule_entry(la::LoopSpec) = _normalize_schedule_entry(_entry_kind(la), 1)

@inline _schedule_entries(la::Union{Plan, ThreadedCompositeAlgorithm}) = Tuple(getschedule(la))
@inline _schedule_entries(la::LoopAlgorithm) = _schedule_entries(getplan(la))

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

function rename(la::LA, replacements::Pair...) where {LA<:LoopSpec}
    _ensure_unresolved_for_edit(la)
    funcs = map(x -> _rename_item(x, replacements), getalgos(la))
    states = map(x -> _rename_item(x, replacements), getstates(la))
    options = map(x -> _rename_item(x, replacements), _stored_constructor_options(la))
    return _rebuild_loopalgorithm(la; funcs, states, options)
end

function insert(la::LA, idx::Integer, algo, schedule_spec = _default_schedule_entry(la)) where {LA<:LoopSpec}
    _ensure_unresolved_for_edit(la)
    newfuncs = _tuple_insert(getalgos(la), idx, _edit_entity(algo))
    schedule_entries = _schedule_entries(la)
    new_schedule_entries = _tuple_insert(schedule_entries, idx, _normalize_schedule_entry(_entry_kind(la), schedule_spec))
    return _rebuild_loopalgorithm(
        la;
        funcs = newfuncs,
        schedule_spec = new_schedule_entries,
    )
end

@inline addalgo(la::LA, algo, schedule_spec = _default_schedule_entry(la)) where {LA<:LoopSpec} = insert(la, length(getalgos(la)) + 1, algo, schedule_spec)

function addstate(la::LA, state) where {LA<:LoopSpec}
    _ensure_unresolved_for_edit(la)
    newstates = (getstates(la)..., _edit_entity(state))
    return _rebuild_loopalgorithm(la; states = newstates)
end

function addoption(la::LA, option) where {LA<:LoopSpec}
    _ensure_unresolved_for_edit(la)
    newoptions = (_stored_constructor_options(la)..., option)
    return _rebuild_loopalgorithm(la; options = newoptions)
end

"""`la` with one interval entry per child from `newintervals` (a number becomes an `Interval`); repeat entries can be given too."""
function changeintervals(la::Union{Plan, ThreadedCompositeAlgorithm, LoopAlgorithm{<:Union{Plan, ThreadedCompositeAlgorithm}}}, newintervals)
    _ensure_unresolved_for_edit(la)
    interval_entries = Tuple(newintervals)
    @assert length(interval_entries) == length(getalgos(la)) "Expected $(length(getalgos(la))) intervals, but got $(length(interval_entries))"
    normalized = map(x -> _normalize_schedule_entry(Val(:interval), x), interval_entries)
    return _rebuild_loopalgorithm(la; schedule_spec = normalized)
end

"""`la` with the entry of child `idx` set to `newinterval` (a number becomes an `Interval`)."""
function changeinterval(la::Union{Plan, ThreadedCompositeAlgorithm, LoopAlgorithm{<:Union{Plan, ThreadedCompositeAlgorithm}}}, idx::Integer, newinterval)
    _ensure_unresolved_for_edit(la)
    normalized = _normalize_schedule_entry(Val(:interval), newinterval)
    interval_entries = _tuple_replace(_schedule_entries(la), idx, normalized)
    return _rebuild_loopalgorithm(la; schedule_spec = interval_entries)
end
