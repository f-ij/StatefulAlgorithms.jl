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

"""The fields of a runtime partition (`_captured_returns`) in context type `RC`, as `name => type` pairs (a slot as the type it holds)."""
function _list_partition_slots(::Type{RC}, partition::Symbol) where {RC<:ProcessContext}
    D = fieldtype(RC, :subcontexts)
    partition in fieldnames(D) || return Pair{Symbol, Any}[]
    return _list_slots(getdatatype(fieldtype(D, partition)))
end
_list_slots(::Type{T}) where {T<:NamedTuple} = Pair{Symbol, Any}[n => _unwrap_slot_type(fieldtype(T, n)) for n in fieldnames(T)]
_unwrap_slot_type(::Type{T}) where {T} = T
_unwrap_slot_type(::Type{<:Maybe{T}}) where {T} = T

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
_build_slots_type(slots) = NamedTuple{Tuple(first.(slots)), Tuple{(make_maybe_type(last(p), UndefInitializer) for p in slots)...}}
_build_owner_slots_type(owners) = NamedTuple{Tuple(first.(owners)), Tuple{last.(owners)...}}

"""
`RC` with output slots for everything the `returned` runtime context types hold in `_captured_returns` and
`_subcontext_returns`, joined with the slots `RC` already has.
"""
function _add_return_slots(::Type{RC}, returned) where {RC<:ProcessContext}
    declared = _list_partition_slots(RC, :_captured_returns)
    owners = Dict{Symbol, Vector{Pair{Symbol, Any}}}(name => _list_slots(T) for (name, T) in _list_partition_slots(RC, :_subcontext_returns))
    owner_order = Symbol[first(p) for p in _list_partition_slots(RC, :_subcontext_returns)]
    for R in returned
        declared = _join_slots(declared, _list_partition_slots(R, :_captured_returns))
        for (owner, T) in _list_partition_slots(R, :_subcontext_returns)
            owner in owner_order || push!(owner_order, owner)
            owners[owner] = _join_slots(get(owners, owner, Pair{Symbol, Any}[]), _list_slots(T))
        end
    end
    partitions = Pair{Symbol, Any}[]
    isempty(declared) || push!(partitions, :_captured_returns => SubContext{:_captured_returns, _build_slots_type(declared)})
    isempty(owner_order) || push!(partitions, :_subcontext_returns => SubContext{:_subcontext_returns, _build_owner_slots_type([o => _build_slots_type(owners[o]) for o in owner_order])})
    return _set_partition_types(RC, partitions)
end

"""Context type `RC` with the subcontext types in `partitions` (name => type) put in, replacing or appending."""
function _set_partition_types(::Type{RC}, partitions) where {RC<:ProcessContext}
    D = fieldtype(RC, :subcontexts)
    names = Symbol[fieldnames(D)...]
    types = Any[fieldtypes(D)...]
    for (name, T) in partitions
        i = findfirst(==(name), names)
        isnothing(i) ? (push!(names, name); push!(types, T)) : (types[i] = T)
    end
    return ProcessContext{NamedTuple{Tuple(names), Tuple{types...}}, fieldtype(RC, :reg)}
end

#=
Typing the runtime context before the loop: the functions below whose names end in `type` or `types` return types;
`_settle_runtime_context` and `_retype_runtime_context` return runtime context values.

An algorithm (or call) in a plan is stepped with a `LoopContext`; inference says what `LoopContext` type its `_step!`
returns, and so what it writes into the runtime context: its returns, and values for declared locals without a value.
=#

"""The runtime context types a step can return (`RT` is a `LoopContext` type or a union of those), or `nothing` if inference could not tell."""
function _collect_returned_contexts(RT)
    loopcontexts = RT === Union{} ? () : Base.uniontypes(RT)
    all(T -> T isa DataType && T <: LoopContext, loopcontexts) || return nothing
    returned = unique(Iterators.flatten(Base.uniontypes(runtime_type(T)) for T in loopcontexts))
    all(C -> C isa DataType && C <: ProcessContext, returned) || return nothing
    return returned
end

"""
The runtime context type after one step, given the type `RuntimeContextType` before it and `stepped`, what inference
says one step returns (`LoopContext` types): declared locals without a value get the types written to them (Locals.jl),
and every return gets a slot for the types written to it. `Nothing` when inference could not tell.
"""
@generated function _add_step_write_types(::Type{RuntimeContextType}, ::Type{Stepped}) where {RuntimeContextType<:ProcessContext, Stepped}
    returned = _collect_returned_contexts(Stepped)
    returned === nothing && return :(Nothing)
    return _add_return_slots(_widen_probes(RuntimeContextType, returned), returned)
end

"""
The expressions that pass the runtime context type `runtime_context_type` through every algorithm (and call) under the
plan of type `PlanType`, in the order they run, appended to `exprs`: one `_runtime_context_type_after_node_step` per
algorithm, with the cursor and wiring view the plan's `_step!` would give it. Nested plans are walked here, while the
code is generated, so inference never sees a plan's `_step!` calling itself.
"""
function _push_per_algorithm_inference_exprs!(exprs, PlanType::Type, plan, cursor, wiring)
    children = fieldtype(PlanType, :funcs)
    namespaces = PlanType.parameters[3]
    for i in 1:fieldcount(children)
        child, child_cursor, child_wiring = gensym(:child), gensym(:cursor), gensym(:wiring)
        push!(exprs, :(local $child = getfield(getfield($plan, :funcs), $i)),
                     :(local $child_cursor = @inline child_loop_cursor($cursor, Val($i))),
                     :(local $child_wiring = @inline child_wiring_view($wiring, Val($i))))
        if fieldtype(children, i) <: AbstractPlan
            _push_per_algorithm_inference_exprs!(exprs, fieldtype(children, i), child, child_cursor, child_wiring)
        else
            push!(exprs, :(runtime_context_type = @inline _runtime_context_type_after_node_step($child, $child_cursor, persistent_context, runtime_context_type, $child_wiring, $(fieldtype(namespaces, i))(), process, lifetime)))
        end
    end
    return exprs
end

"""
    _infer_runtime_context_type_per_algorithm(plan, cursor, persistent_context, RuntimeContextType, wiring, process, lifetime)

The runtime context type after one step of `plan`, given the type `RuntimeContextType` before it, found by inferring
each algorithm (and call) of the plan on its own, in the order they run (`_push_per_algorithm_inference_exprs!`). `Any` when
inference cannot tell.

Why not infer the plan's `_step!` as a whole: a nested plan's `_step!` is the same method, called with a runtime
context type that has grown (every algorithm before it added its returns). Julia's inference stops following a method
that calls itself with a growing argument type, and then answers `Any` for the whole step. Inferring one algorithm at a
time, with the nested plans unrolled in one generated body, avoids that. Only the first round of typing needs it: once
every return has a slot, the runtime context type no longer grows within a step (`_infer_runtime_context_type_after_whole_step`).
"""
@inline @generated function _infer_runtime_context_type_per_algorithm(plan::PlanType, cursor::CursorType, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, process::ProcessType, lifetime::LifetimeType) where {PlanType<:AbstractPlan, CursorType, PersistentContextType, RuntimeContextType, WiringViewType, ProcessType, LifetimeType}
    exprs = Any[:(runtime_context_type = RuntimeContextType)]
    _push_per_algorithm_inference_exprs!(exprs, PlanType, :plan, :cursor, :wiring)
    push!(exprs, :(return runtime_context_type))
    return Expr(:block, exprs...)
end

"""
The runtime context type after the first step, from `RuntimeContextType` (its declared locals without a value as
probes, see Locals.jl), inferred per algorithm (`_infer_runtime_context_type_per_algorithm`): every return gets a
slot, every declared local without a value the type written to it. `Nothing` when inference cannot tell.
"""
@inline _infer_runtime_context_type_after_first_step(::Type{RuntimeContextType}, plan::PlanType, cursor::CursorType, persistent_context::PersistentContextType, wiring::WiringViewType, process::ProcessType, lifetime::LifetimeType) where {RuntimeContextType, PlanType, CursorType, PersistentContextType, WiringViewType, ProcessType, LifetimeType} =
    _add_step_write_types(RuntimeContextType, _build_returned_loopcontext_types(PersistentContextType, (@inline _infer_runtime_context_type_per_algorithm(plan, cursor, persistent_context, RuntimeContextType, wiring, process, lifetime)), WiringViewType))

"""The `LoopContext` types for the runtime context type(s) `RuntimeContextType`; `Any` when those are not known."""
Base.@assume_effects :foldable _build_returned_loopcontext_types(@nospecialize(PersistentContextType), @nospecialize(RuntimeContextType), @nospecialize(WiringViewType)) =
    all(T -> T isa DataType && T <: ProcessContext, Base.uniontypes(RuntimeContextType)) ? _loop_context_type(PersistentContextType, RuntimeContextType, WiringViewType) : Any

"""The plan's step as inference sees it for typing: `_step!` without a namespace. Only inferred, never run."""
@inline _probe_step(plan, cursor, lc, wiring, process, lifetime) =
    _step!(plan, cursor, lc, wiring, Namespace{nothing}(), process, lifetime)

"""
The runtime context type after one step from `RuntimeContextType`, inferring the plan's step as a whole (see
`_add_step_write_types`). Used once every return has a slot.
"""
@inline _infer_runtime_context_type_after_whole_step(::Type{RuntimeContextType}, plan::PlanType, cursor::CursorType, persistent_context::PersistentContextType, wiring::WiringViewType, process::ProcessType, lifetime::LifetimeType) where {RuntimeContextType, PlanType, CursorType, PersistentContextType, WiringViewType, ProcessType, LifetimeType} =
    _add_step_write_types(RuntimeContextType, Core.Compiler.return_type(_probe_step, Tuple{PlanType, CursorType, LoopContext{PersistentContextType, RuntimeContextType, wiring_parent(WiringViewType)}, WiringViewType, ProcessType, LifetimeType}))

"""Whether the declared locals of two runtime context types have the same types."""
_has_same_locals(::Type{A}, ::Type{B}) where {A, B} = _get_locals_type(A) === _get_locals_type(B)
_has_same_locals(::Type{A}, ::Type{Nothing}) where {A} = false

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
        if name in fieldnames(NT) && fieldtype(NT, name) <: Maybe && fieldtype(A, name) <: _unwrap_slot_type(fieldtype(NT, name))
            return :($(fieldtype(NT, name))(getfield(args, $(QuoteNode(name)))))
        end
        return :(getfield(args, $(QuoteNode(name))))
    end
    return :(NamedTuple{$(Tuple(names))}(($(values...),)))
end

"""
    _settle_runtime_context(plan, cursor, persistent_context, runtime_context, wiring, process, lifetime)

The runtime context the loop starts with: `runtime_context` with its types decided before the first step, so it has
the same type in every step. Every return gets a typed slot (unset), every declared local without a value the type of
what is written to it. Returns a value; all of it is worked out while the run is compiled, nothing of it runs per step.

1. The declared locals without a value become probes, and one step is inferred per algorithm
   (`_infer_runtime_context_type_after_first_step`): what is written to each declared local and what is returned. The
   declared locals get their types, the returns typed slots.
2. A second round, with these types, inferring the step as a whole, checks the rule that a declared local keeps the
   type of its first value (an error otherwise, naming the step). It can still widen a return slot: a return computed
   from a declared local (`v = f(y)`) is only known once that local's type is.
3. If the second round changed something, a third round must not. If the returns do not settle, or inference cannot
   tell, the returns get no slots and take their types as written; entering a scope then removes them.
"""
@inline function _settle_runtime_context(plan, cursor, persistent_context, runtime_context::RuntimeContextType, wiring, process, lifetime) where {RuntimeContextType<:ProcessContext}
    step = (plan, cursor, persistent_context, wiring, process, lifetime)
    has_untyped_locals = _has_untyped_locals(RuntimeContextType)
    no_writes_seen = _insert_probes(RuntimeContextType)
    first_round = _infer_runtime_context_type_after_first_step(no_writes_seen, step...)
    if first_round === Nothing
        has_untyped_locals && _throw_uninferrable_step_error(no_writes_seen, step...)
        return runtime_context
    end
    second_round = _infer_runtime_context_type_after_whole_step(first_round, step...)
    has_untyped_locals && !_has_same_locals(first_round, second_round) && _throw_local_type_change_error(first_round, step...)
    settled = second_round === first_round ? first_round :
        second_round === Nothing ? Nothing :
        _infer_runtime_context_type_after_whole_step(second_round, step...) === second_round ? second_round : Nothing
    settled === Nothing && return has_untyped_locals ? (@inline _retype_runtime_context(runtime_context, _drop_returns(first_round))) : runtime_context
    return @inline _retype_runtime_context(runtime_context, settled)
end

_drop_returns(::Type{R}) where {R<:ProcessContext} = _drop_partitions(R, (:_captured_returns, :_subcontext_returns))
function _drop_partitions(::Type{RC}, drop) where {RC<:ProcessContext}
    D = fieldtype(RC, :subcontexts)
    keep = [i for (i, n) in enumerate(fieldnames(D)) if !(n in drop)]
    return ProcessContext{NamedTuple{Tuple(fieldnames(D)[keep]), Tuple{fieldtypes(D)[keep]...}}, fieldtype(RC, :reg)}
end

"""A value of slots type `T` (a named tuple, possibly of named tuples) with every slot unset."""
_build_empty_slots_expr(::Type{T}) where {T<:NamedTuple} =
    :($T(($((fieldtype(T, n) <: NamedTuple ? _build_empty_slots_expr(fieldtype(T, n)) : :($(fieldtype(T, n))()) for n in fieldnames(T))...),)))

"""`runtime_context` with the types of `TypedRuntimeContextType`: declared locals without a value as unset `Maybe`s of their type, and every return slot unset."""
@inline @generated function _retype_runtime_context(runtime_context::RuntimeContextType, ::Type{TypedRuntimeContextType}) where {RuntimeContextType<:ProcessContext, TypedRuntimeContextType<:ProcessContext}
    exprs = Any[:(typed = runtime_context)]
    if _has_untyped_locals(RuntimeContextType)
        push!(exprs, :(typed = @inline with_subcontext(typed, Val(:_declared_locals), SubContext{:_declared_locals}(_settle_locals(get_declared_locals(typed), $TypedRuntimeContextType)))))
    end
    subcontexts = fieldtype(TypedRuntimeContextType, :subcontexts)
    for partition in (:_captured_returns, :_subcontext_returns)
        partition in fieldnames(subcontexts) || continue
        push!(exprs, :(typed = @inline with_subcontext(typed, Val($(QuoteNode(partition))), $(fieldtype(subcontexts, partition))($(_build_empty_slots_expr(getdatatype(fieldtype(subcontexts, partition))))))))
    end
    push!(exprs, :(return typed))
    return Expr(:block, exprs...)
end

"""A named tuple of type `T` read from `source`, with the fields in `names` unset: a slot unset, any other one left out."""
function _build_unset_expr(::Type{T}, names, source) where {T<:NamedTuple}
    kept = Tuple(n for n in fieldnames(T) if !(n in names) || fieldtype(T, n) <: Maybe)
    values = map(n -> n in names ? :($(fieldtype(T, n))()) : :(getfield($source, $(QuoteNode(n)))), kept)
    return :(NamedTuple{$kept}(($(values...),)))
end

"""
    _unset_returns(runtime_context, Val(resets))

`runtime_context` with the returns in `resets` unset (`(; returns, owners)`, see `enter_scope`): the captured returns
named in `returns`, and every subcontext return of the namespaces in `owners`. A slot is made unset; a return without
one (not typed before the run) is removed.
"""
@inline @generated function _unset_returns(runtime_context::RC, ::Val{Resets}) where {RC<:ProcessContext, Resets}
    D = fieldtype(RC, :subcontexts)
    exprs = Any[:(rc = runtime_context)]
    if :_captured_returns in fieldnames(D)
        T = getdatatype(fieldtype(D, :_captured_returns))
        if any(in(fieldnames(T)), Resets.returns)
            data = _build_unset_expr(T, Resets.returns, :(get_captured_returns(rc)))
            push!(exprs, :(rc = @inline with_subcontext(rc, Val(:_captured_returns), SubContext{:_captured_returns}($data))))
        end
    end
    if :_subcontext_returns in fieldnames(D)
        T = getdatatype(fieldtype(D, :_subcontext_returns))
        if any(in(fieldnames(T)), Resets.owners)
            kept = Tuple(o for o in fieldnames(T) if !(o in Resets.owners) || any(F -> F <: Maybe, fieldtypes(fieldtype(T, o))))
            values = map(kept) do o
                source = :(getfield(get_subcontext_returns(rc), $(QuoteNode(o))))
                o in Resets.owners ? _build_unset_expr(fieldtype(T, o), fieldnames(fieldtype(T, o)), source) : source
            end
            data = :(NamedTuple{$kept}(($(values...),)))
            push!(exprs, :(rc = @inline with_subcontext(rc, Val(:_subcontext_returns), SubContext{:_subcontext_returns}($data))))
        end
    end
    push!(exprs, :(return rc))
    return Expr(:block, exprs...)
end
