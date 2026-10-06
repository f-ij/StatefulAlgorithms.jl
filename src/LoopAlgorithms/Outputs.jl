#=
Typing the run's values before the first step.

A run holds, next to the stored state: inputs (read-only), declared locals (the run) and returns (captured returns,
what statements and calls return, and subcontext returns, what an algorithm returns that is not its state). A return
lives for one step of the plan node it belongs to: entering the node makes it unset (`enter_scope`).
Like Julia does for the variables of a function, their types are decided before the loop, from the types the steps
write, so the runtime context has one type in every step:

- a declared local without a type (`local x`, `x = nothing`) gets the type of its first value and keeps it (Locals.jl);
- a return gets a slot, a `Maybe` of every type written to it, unset until it is written in a step (e.g. `v = f(y)`
  gets `Maybe{Float64}`; reading it before it is written is an `UndefRefError`). Writing it converts the value into the
  slot (`_merge_slots`).

Without these slots a return would only appear in the runtime context when first written, and a value that is
`nothing` in some steps and a `Float64` in others would change the runtime context's type from step to step.
=#

"""The fields of a runtime part (`_captured_returns`) in context type `RC`, as `name => type` pairs (a slot as the type it holds)."""
function _part_slots(::Type{RC}, part::Symbol) where {RC<:ProcessContext}
    D = fieldtype(RC, :subcontexts)
    part in fieldnames(D) || return Pair{Symbol, Any}[]
    return _slots_of(getdatatype(fieldtype(D, part)))
end
_slots_of(::Type{T}) where {T<:NamedTuple} = Pair{Symbol, Any}[n => _slot_value_type(fieldtype(T, n)) for n in fieldnames(T)]
_slot_value_type(::Type{T}) where {T} = T
_slot_value_type(::Type{<:Maybe{T}}) where {T} = T

"""`slots` (name => type, in order) joined with the `written` ones: every written type is added."""
function _join_slots(slots::Vector{Pair{Symbol, Any}}, written)
    joined = copy(slots)
    for (name, T) in written
        i = findfirst(p -> first(p) === name, joined)
        isnothing(i) ? push!(joined, name => T) : (joined[i] = name => Union{last(joined[i]), T})
    end
    return joined
end

"""The named tuple type of slots `name => type`: each an unset-able `Maybe` of its type."""
_slots_type(slots) = NamedTuple{Tuple(first.(slots)), Tuple{(maybe_type(last(p), UndefInitializer) for p in slots)...}}
_owner_slots_type(owners) = NamedTuple{Tuple(first.(owners)), Tuple{last.(owners)...}}

"""
`RC` with output slots for everything the `returned` runtime context types hold in `_captured_returns` and
`_subcontext_returns`, joined with the slots `RC` already has.
"""
function _with_output_slots(::Type{RC}, returned) where {RC<:ProcessContext}
    declared = _part_slots(RC, :_captured_returns)
    owners = Dict{Symbol, Vector{Pair{Symbol, Any}}}(name => _slots_of(T) for (name, T) in _part_slots(RC, :_subcontext_returns))
    owner_order = Symbol[first(p) for p in _part_slots(RC, :_subcontext_returns)]
    for R in returned
        declared = _join_slots(declared, _part_slots(R, :_captured_returns))
        for (owner, T) in _part_slots(R, :_subcontext_returns)
            owner in owner_order || push!(owner_order, owner)
            owners[owner] = _join_slots(get(owners, owner, Pair{Symbol, Any}[]), _slots_of(T))
        end
    end
    parts = Pair{Symbol, Any}[]
    isempty(declared) || push!(parts, :_captured_returns => SubContext{:_captured_returns, _slots_type(declared)})
    isempty(owner_order) || push!(parts, :_subcontext_returns => SubContext{:_subcontext_returns, _owner_slots_type([o => _slots_type(owners[o]) for o in owner_order])})
    return _with_parts(RC, parts)
end

"""Context type `RC` with the subcontext types in `parts` (name => type) put in, replacing or appending."""
function _with_parts(::Type{RC}, parts) where {RC<:ProcessContext}
    D = fieldtype(RC, :subcontexts)
    names = Symbol[fieldnames(D)...]
    types = Any[fieldtypes(D)...]
    for (name, T) in parts
        i = findfirst(==(name), names)
        isnothing(i) ? (push!(names, name); push!(types, T)) : (types[i] = T)
    end
    return ProcessContext{NamedTuple{Tuple(names), Tuple{types...}}, fieldtype(RC, :reg)}
end

"""
The runtime context type after one step with the context type `RC`: its untyped locals widened by what was written
(Locals.jl) and its output slots joined with what was returned. `RT` is what inference says one plan step returns;
`Nothing` when it could not tell.
"""
@generated function _next_runtime_type(::Type{RC}, ::Type{RT}) where {RC<:ProcessContext, RT}
    returned = _inferred_contexts(RT)
    returned === nothing && return :(Nothing)
    return _with_output_slots(_probe_joined_type(RC, returned), returned)
end

"""
The runtime context type after the first plan step from `R`, inferred leaf by leaf (`_runtime_by_leaves`): the
returns get their slots, and the untyped locals what is written to them. `Nothing` when inference cannot tell.
"""
@inline _first_runtime(::Type{R}, plan::PL, cursor::CU, context::C, wiring::W, process::P, lifetime::LT) where {R, PL, CU, C, W, P, LT} =
    _next_runtime_type(R, _returned_loopcontexts(C, (@inline _runtime_by_leaves(plan, cursor, context, R, wiring, process, lifetime)), W))

"""The `LoopContext` types for the runtime type(s) `RC` (see `_inferred_contexts`); `Any` when `RC` is not known."""
Base.@assume_effects :foldable _returned_loopcontexts(@nospecialize(C), @nospecialize(RC), @nospecialize(W)) =
    all(T -> T isa DataType && T <: ProcessContext, Base.uniontypes(RC)) ? _loop_context_type(C, RC, W) : Any

"""The runtime context type after one plan step from `R` (see `_next_runtime_type`)."""
@inline _widen_runtime(::Type{R}, plan::PL, cursor::CU, context::C, wiring::W, process::P, lifetime::LT) where {R, PL, CU, C, W, P, LT} =
    _next_runtime_type(R, Core.Compiler.return_type(_probe_step, Tuple{PL, CU, LoopContext{C, R, wiring_parent(W)}, W, P, LT}))

"""Whether the declared locals of two runtime context types have the same types."""
_same_locals(::Type{A}, ::Type{B}) where {A, B} = _local_data_type(A) === _local_data_type(B)
_same_locals(::Type{A}, ::Type{Nothing}) where {A} = false

"""
`merge(old, args)`, except that a value written to a slot (a `Maybe`, see the note above) is put into it, so the field
keeps its type and the runtime context has the same type in every step. A value that does not fit the slot (a return
that could not be typed before the run) replaces the field as `merge` does.
"""
@inline @generated function _merge_slots(old::NT, args::A) where {NT<:NamedTuple, A<:NamedTuple}
    names = Symbol[fieldnames(NT)...]
    append!(names, (n for n in fieldnames(A) if !(n in fieldnames(NT))))
    values = map(names) do name
        name in fieldnames(A) || return :(getfield(old, $(QuoteNode(name))))
        if name in fieldnames(NT) && fieldtype(NT, name) <: Maybe && fieldtype(A, name) <: _slot_value_type(fieldtype(NT, name))
            return :($(fieldtype(NT, name))(getfield(args, $(QuoteNode(name)))))
        end
        return :(getfield(args, $(QuoteNode(name))))
    end
    return :(NamedTuple{$(Tuple(names))}(($(values...),)))
end

"""
    _settle_runtime(plan, cursor, context, runtimecontext, wiring, process, lifetime)

The runtime context the loop starts with, typed before the first step (see the note above). All of it is resolved while
the run is compiled; nothing of it runs per step.

1. Untyped declared locals become probes; inference runs one step, leaf by leaf (`_first_runtime`), and reads off
   what is written to each local and what is returned. The locals get their types, the returns typed slots.
2. A second round, with these types, checks the rule that a declared local keeps its type after its first value
   (an error otherwise, naming the step). It can still widen a return slot: a return computed from a local
   (`v = f(y)`) is only known once the local's type is. With every slot in place, the step is inferred as a whole.
3. If it did, a third round must not change anything. If the returns do not settle, or inference cannot tell, the
   returns get no slots and take their types as written; entering a scope then removes them.
"""
@inline function _settle_runtime(plan, cursor, context, runtimecontext::RC, wiring, process, lifetime) where {RC<:ProcessContext}
    step = (plan, cursor, context, wiring, process, lifetime)
    untyped = _has_untyped_locals(RC)
    no_writes_seen = _probe_runtime_type(RC)
    first_round = _first_runtime(no_writes_seen, step...)
    if first_round === Nothing
        untyped && _local_type_error(no_writes_seen, false, step...)
        return runtimecontext
    end
    second_round = _widen_runtime(first_round, step...)
    untyped && !_same_locals(first_round, second_round) && _local_type_error(first_round, true, step...)
    settled = second_round === first_round ? first_round :
        second_round === Nothing ? Nothing :
        _widen_runtime(second_round, step...) === second_round ? second_round : Nothing
    settled === Nothing && return untyped ? (@inline _settled_runtime(runtimecontext, _without_returns(first_round))) : runtimecontext
    return @inline _settled_runtime(runtimecontext, settled)
end

_without_returns(::Type{R}) where {R<:ProcessContext} = _drop_parts(R, (:_captured_returns, :_subcontext_returns))
function _drop_parts(::Type{RC}, drop) where {RC<:ProcessContext}
    D = fieldtype(RC, :subcontexts)
    keep = [i for (i, n) in enumerate(fieldnames(D)) if !(n in drop)]
    return ProcessContext{NamedTuple{Tuple(fieldnames(D)[keep]), Tuple{fieldtypes(D)[keep]...}}, fieldtype(RC, :reg)}
end

"""A value of slots type `T` (a named tuple, possibly of named tuples) with every slot unset."""
_empty_slots_expr(::Type{T}) where {T<:NamedTuple} =
    :($T(($((fieldtype(T, n) <: NamedTuple ? _empty_slots_expr(fieldtype(T, n)) : :($(fieldtype(T, n))()) for n in fieldnames(T))...),)))

"""`runtimecontext` with the types of `R`: untyped locals as unset `Maybe`s of their type, and return slots unset."""
@inline @generated function _settled_runtime(runtimecontext::RC, ::Type{R}) where {RC<:ProcessContext, R<:ProcessContext}
    exprs = Any[:(rc = runtimecontext)]
    if _has_untyped_locals(RC)
        push!(exprs, :(rc = @inline with_subcontext(rc, Val(:_declared_locals), SubContext{:_declared_locals}(_settled_locals(get_declared_locals(rc), $R)))))
    end
    D = fieldtype(R, :subcontexts)
    for part in (:_captured_returns, :_subcontext_returns)
        part in fieldnames(D) || continue
        push!(exprs, :(rc = @inline with_subcontext(rc, Val($(QuoteNode(part))), $(fieldtype(D, part))($(_empty_slots_expr(getdatatype(fieldtype(D, part))))))))
    end
    push!(exprs, :(return rc))
    return Expr(:block, exprs...)
end

"""A named tuple of type `T` read from `source`, with the fields in `names` unset: a slot unset, any other one left out."""
function _unset_expr(::Type{T}, names, source) where {T<:NamedTuple}
    kept = Tuple(n for n in fieldnames(T) if !(n in names) || fieldtype(T, n) <: Maybe)
    values = map(n -> n in names ? :($(fieldtype(T, n))()) : :(getfield($source, $(QuoteNode(n)))), kept)
    return :(NamedTuple{$kept}(($(values...),)))
end

"""
    _unset_returns(runtimecontext, Val(resets))

`runtimecontext` with the returns in `resets` unset (`(; returns, owners)`, see `enter_scope`): the captured returns
named in `returns`, and every subcontext return of the namespaces in `owners`. A slot is made unset; a return without
one (not typed before the run) is removed.
"""
@inline @generated function _unset_returns(runtimecontext::RC, ::Val{Resets}) where {RC<:ProcessContext, Resets}
    D = fieldtype(RC, :subcontexts)
    exprs = Any[:(rc = runtimecontext)]
    if :_captured_returns in fieldnames(D)
        T = getdatatype(fieldtype(D, :_captured_returns))
        if any(in(fieldnames(T)), Resets.returns)
            data = _unset_expr(T, Resets.returns, :(get_captured_returns(rc)))
            push!(exprs, :(rc = @inline with_subcontext(rc, Val(:_captured_returns), SubContext{:_captured_returns}($data))))
        end
    end
    if :_subcontext_returns in fieldnames(D)
        T = getdatatype(fieldtype(D, :_subcontext_returns))
        if any(in(fieldnames(T)), Resets.owners)
            kept = Tuple(o for o in fieldnames(T) if !(o in Resets.owners) || any(F -> F <: Maybe, fieldtypes(fieldtype(T, o))))
            values = map(kept) do o
                source = :(getfield(get_subcontext_returns(rc), $(QuoteNode(o))))
                o in Resets.owners ? _unset_expr(fieldtype(T, o), fieldnames(fieldtype(T, o)), source) : source
            end
            data = :(NamedTuple{$kept}(($(values...),)))
            push!(exprs, :(rc = @inline with_subcontext(rc, Val(:_subcontext_returns), SubContext{:_subcontext_returns}($data))))
        end
    end
    push!(exprs, :(return rc))
    return Expr(:block, exprs...)
end
