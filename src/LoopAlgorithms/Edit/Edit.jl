# User-facing edits of an unresolved LoopAlgorithm: rename keys, insert/add algorithms,
# add states and options, change intervals. Each returns a rebuilt algorithm; the
# helpers they use live in Backend.jl.

export insert, addalgo, addstate, addoption, rename, changeinterval, changeintervals

import Base: rename

include("Backend.jl")

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
    new_schedule_entries = _tuple_insert(schedule_entries, idx, _normalize_schedule_entry(la, schedule_spec))
    return _rebuild_loopalgorithm(
        la;
        funcs = newfuncs,
        schedule_spec = _collapse_schedule_spec(la, new_schedule_entries),
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

function changeintervals(la::Union{CompositeAlgorithm, ThreadedCompositeAlgorithm, LoopAlgorithm{<:CompositeAlgorithm}}, newintervals)
    _ensure_unresolved_for_edit(la)
    interval_entries = Tuple(newintervals)
    @assert length(interval_entries) == length(getalgos(la)) "Expected $(length(getalgos(la))) intervals, but got $(length(interval_entries))"
    normalized = map(x -> _normalize_schedule_entry(la, x), interval_entries)
    return _rebuild_loopalgorithm(
        la;
        schedule_spec = _collapse_schedule_spec(la, normalized),
    )
end

function changeinterval(la::Union{CompositeAlgorithm, ThreadedCompositeAlgorithm, LoopAlgorithm{<:CompositeAlgorithm}}, idx::Integer, newinterval)
    _ensure_unresolved_for_edit(la)
    normalized = _normalize_schedule_entry(la, newinterval)
    interval_entries = _tuple_replace(_schedule_entries(la), idx, normalized)
    return _rebuild_loopalgorithm(
        la;
        schedule_spec = _collapse_schedule_spec(la, interval_entries),
    )
end
