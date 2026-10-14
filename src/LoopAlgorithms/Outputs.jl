#=
Typing the run's values before the first step, and removing a plan node's returns when it ends.

A run holds, next to the stored state: inputs (read-only), declared locals and returns (captured returns, what
statements and calls return, and subcontext returns, what an algorithm returns that is not its state). A return exists
from the line that writes it to the end of its plan node (`leave_scope` removes it, `_strip_returns`), so a step ends
with the runtime context it started with.

A declared local without a value (`local x`) has no value before the first step, but the runtime context needs its type
from the start, as Julia needs a variable's type before a loop. So its type is decided before the loop from the types
the steps write to it (`_settle_runtime_context`), and it is held in an unset `Maybe` of that type until it
is written (`_merge_slots` puts a written value into it).
=#

"""The type a declared local's `Maybe` holds (the type itself for a value that is not a `Maybe`)."""
_unwrap_slot_type(::Type{T}) where {T} = T
_unwrap_slot_type(::Type{<:Maybe{T}}) where {T} = T

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
says one step returns (`LoopContext` types): declared locals without a value get the types written to them (Locals.jl).
`Nothing` when inference could not tell.
"""
@generated function _add_step_write_types(::Type{RuntimeContextType}, ::Type{Stepped}) where {RuntimeContextType<:ProcessContext, Stepped}
    returned = _collect_returned_contexts(Stepped)
    returned === nothing && return :(Nothing)
    return _widen_probes(RuntimeContextType, returned)
end

"""
The runtime context type after `_step!(node, ...)` has run, given the type `RuntimeContextType` before it: the type the
step returns (`RuntimeContextType` when the step cannot return, `Any` when inference cannot tell).

For the first round of typing only. Unlike `_runtime_context_type_after_node_step` it does not keep the type before
the step as an alternative (for a node that may not run): with that union, the node after it is inferred once per
earlier node, so the first round grows with the square of the number of nodes. A step that reads a return of a node
that did not run fails, so the alternative adds no written types; the later rounds, with every return in a slot that
may be unset, check the result.
"""
@inline function _runtime_context_type_after_node_run(node::NodeType, cursor::CursorType, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType) where {NodeType, CursorType, PersistentContextType, RuntimeContextType, WiringViewType, NamespaceType, ProcessType, LifetimeType}
    RuntimeContextType <: ProcessContext || return Any
    stepped = Core.Compiler.return_type(_step!, Tuple{NodeType, CursorType, _loop_context_type(PersistentContextType, RuntimeContextType, WiringViewType), WiringViewType, NamespaceType, ProcessType, LifetimeType})
    after = _runtime_context_types_of(stepped)
    return after === Union{} ? RuntimeContextType : after
end

"""
The expressions that pass the runtime context type `runtime_context_type` through every algorithm (and call) under the
plan of type `PlanType`, in the order they run, appended to `exprs`: one `_runtime_context_type_after_node_run` per
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
            push!(exprs, :(runtime_context_type = @inline _runtime_context_type_after_node_run($child, $child_cursor, persistent_context, runtime_context_type, $child_wiring, $(fieldtype(namespaces, i))(), process, lifetime)))
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
time, with the nested plans unrolled in one generated body, avoids that. The later rounds infer the step as a whole
(`_infer_runtime_context_type_after_whole_step`).
TODO: nested plans are now written into their parent's `_step!` (Step.jl), so inferring the whole step may work in the
first round too; not checked.
"""
@inline @generated function _infer_runtime_context_type_per_algorithm(plan::PlanType, cursor::CursorType, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, process::ProcessType, lifetime::LifetimeType) where {PlanType<:AbstractPlan, CursorType, PersistentContextType, RuntimeContextType, WiringViewType, ProcessType, LifetimeType}
    exprs = Any[:(runtime_context_type = RuntimeContextType)]
    _push_per_algorithm_inference_exprs!(exprs, PlanType, :plan, :cursor, :wiring)
    push!(exprs, :(return runtime_context_type))
    return Expr(:block, exprs...)
end

"""
The runtime context type after the first step, from `RuntimeContextType` (its declared locals without a value as
probes, see Locals.jl), inferred per algorithm (`_infer_runtime_context_type_per_algorithm`): every declared local
without a value gets the type written to it. `Nothing` when inference cannot tell.
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
`_add_step_write_types`). Used from the second round of typing on.
"""
@inline _infer_runtime_context_type_after_whole_step(::Type{RuntimeContextType}, plan::PlanType, cursor::CursorType, persistent_context::PersistentContextType, wiring::WiringViewType, process::ProcessType, lifetime::LifetimeType) where {RuntimeContextType, PlanType, CursorType, PersistentContextType, WiringViewType, ProcessType, LifetimeType} =
    _add_step_write_types(RuntimeContextType, Core.Compiler.return_type(_probe_step, Tuple{PlanType, CursorType, LoopContext{PersistentContextType, RuntimeContextType, read_parent_wiring_type(WiringViewType)}, WiringViewType, ProcessType, LifetimeType}))

"""Whether the declared locals of two runtime context types have the same types."""
_has_same_locals(::Type{A}, ::Type{B}) where {A, B} = _get_locals_type(A) === _get_locals_type(B)
_has_same_locals(::Type{A}, ::Type{Nothing}) where {A} = false

"""The body of `_merge_slots` for named tuple types `NT` and `A`."""
# Loops, not closures: a closure over a type is compiled again for every type.
function _merge_slots_expr(@nospecialize(NT::Type), @nospecialize(A::Type))
    names = Symbol[fieldnames(NT)...]
    for n in fieldnames(A)
        n in fieldnames(NT) || push!(names, n)
    end
    values = Any[]
    for name in names
        if !(name in fieldnames(A))
            push!(values, :(getfield(old, $(QuoteNode(name)))))
        elseif name in fieldnames(NT) && fieldtype(NT, name) <: Maybe && fieldtype(A, name) <: _unwrap_slot_type(fieldtype(NT, name))
            push!(values, :($(fieldtype(NT, name))(getfield(args, $(QuoteNode(name))))))
        else
            push!(values, :(getfield(args, $(QuoteNode(name)))))
        end
    end
    return :(NamedTuple{$(Tuple(names))}(($(values...),)))
end

"""
`merge(old, args)`, except that a value written to a declared local held in a `Maybe` (see the note at the top) is
put into it, so the field keeps its type and the runtime context has the same type in every step. A value that does
not fit replaces the field as `merge` does.
"""
@inline @generated _merge_slots(old::NT, args::A) where {NT<:NamedTuple, A<:NamedTuple} = _merge_slots_expr(NT, A)

"""
    _settle_runtime_context(plan, cursor, persistent_context, runtime_context, wiring, process, lifetime)

The runtime context the loop starts with: `runtime_context` with every declared local without a value as an unset
`Maybe` of the type written to it, so the runtime context has the same type in every step. Returns a value; all of it
is worked out while the run is compiled, nothing of it runs per step.

1. The declared locals without a value become probes, and one step is inferred per algorithm
   (`_infer_runtime_context_type_after_first_step`): what is written to each declared local gives its type.
2. A second round, with these types, inferring the step as a whole, checks the rule that a declared local keeps the
   type of its first value (an error otherwise, naming the step). It can still change a type: a local computed from
   another declared local (`y = f(x)`) is only known once that local's type is.
3. If the second round changed something, a third round must not. If the types do not settle, or inference cannot
   tell, the declared locals keep the types of the first round.
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

"""`runtime_context` with the declared locals of `TypedRuntimeContextType`: those without a value as unset `Maybe`s of their type."""
@inline @generated function _retype_runtime_context(runtime_context::RuntimeContextType, ::Type{TypedRuntimeContextType}) where {RuntimeContextType<:ProcessContext, TypedRuntimeContextType<:ProcessContext}
    exprs = Any[:(typed = runtime_context)]
    if _has_untyped_locals(RuntimeContextType)
        push!(exprs, :(typed = @inline with_subcontext(typed, Val(:_declared_locals), SubContext{:_declared_locals}(_settle_locals(get_declared_locals(typed), $TypedRuntimeContextType)))))
    end
    push!(exprs, :(return typed))
    return Expr(:block, exprs...)
end

"""
    _strip_returns(runtime_context, Val(resets))

`runtime_context` without the returns in `resets` (`(; returns, owners)`, see `node_resets`): the captured returns named
in `returns`, and every subcontext return of the namespaces in `owners`. What a plan node leaves behind when it ends.
"""
@inline @generated function _strip_returns(runtime_context::RuntimeContextType, ::Val{Resets}) where {RuntimeContextType<:ProcessContext, Resets}
    Resets isa NamedTuple || return :runtime_context      # outside every node: nothing to strip
    subcontexts = fieldtype(RuntimeContextType, :subcontexts)
    names, values = Symbol[], Any[]
    for (name, S) in zip(fieldnames(subcontexts), fieldtypes(subcontexts))
        source = :(getfield(get_subcontexts(runtime_context), $(QuoteNode(name))))
        removed = name === :_captured_returns ? Resets.returns : name === :_subcontext_returns ? Resets.owners : ()
        data = getdatatype(S)
        kept = Tuple(n for n in fieldnames(data) if !(n in removed))
        if length(kept) == fieldcount(data)
            push!(names, name); push!(values, source)
        elseif !isempty(kept)          # a part left empty is removed, so the type is the one before the node
            fields = [:(getfield(getdata($source), $(QuoteNode(n)))) for n in kept]
            push!(names, name); push!(values, :(SubContext{$(QuoteNode(name))}(NamedTuple{$kept}(($(fields...),)))))
        end
    end
    length(names) == fieldcount(subcontexts) && all(v -> v isa Expr && v.args[1] === :getfield, values) && return :runtime_context
    return :(ProcessContext(NamedTuple{$(Tuple(names))}(($(values...),)), getfield(runtime_context, :reg)))
end
