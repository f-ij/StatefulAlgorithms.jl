#=
Typing the run's values before the first step.

A run holds, next to the stored state: inputs (read-only), declared locals (the run) and outputs (one step: declared
outputs, what statements and calls return, and subcontext returns, what an algorithm returns that is not its state).
Like Julia does for the variables of a function, their types are decided before the loop, from the types the steps
write, so the runtime context has one type in every step:

- a declared local without a type (`local x`, `x = nothing`) gets the type of its first value and keeps it (Locals.jl);
- an output gets a slot whose type is every type written to it, and `Nothing` for the steps before its first write
  (e.g. `v = f(y)` gets `Union{Nothing, Float64}`). Writing it keeps that type (`_merge_slots`).

Without these slots an output would only appear in the runtime context when first written, and a value that is
`nothing` in some steps and a `Float64` in others would change the runtime context's type from step to step.
=#

"""The names and types of a runtime part (`_captured_returns`) in context type `RC`, as `name => type` pairs."""
function _part_slots(::Type{RC}, part::Symbol) where {RC<:ProcessContext}
    D = fieldtype(RC, :subcontexts)
    part in fieldnames(D) || return Pair{Symbol, Any}[]
    T = getdatatype(fieldtype(D, part))
    return Pair{Symbol, Any}[n => fieldtype(T, n) for n in fieldnames(T)]
end

"""`slots` (name => type, in order) joined with the `written` ones: every written type is added, and `Nothing` for a new name."""
function _join_slots(slots::Vector{Pair{Symbol, Any}}, written)
    joined = copy(slots)
    for (name, T) in written
        i = findfirst(p -> first(p) === name, joined)
        if isnothing(i)
            push!(joined, name => Union{Nothing, T})
        else
            joined[i] = name => Union{last(joined[i]), T}
        end
    end
    return joined
end

_slots_type(slots) = NamedTuple{Tuple(first.(slots)), Tuple{last.(slots)...}}

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
    isempty(owner_order) || push!(parts, :_subcontext_returns => SubContext{:_subcontext_returns, _slots_type([o => _slots_type(owners[o]) for o in owner_order])})
    return _with_parts(RC, parts)
end

_slots_of(::Type{T}) where {T<:NamedTuple} = Pair{Symbol, Any}[n => fieldtype(T, n) for n in fieldnames(T)]

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

"""The runtime context type after one plan step from `R` (see `_next_runtime_type`)."""
@inline _widen_runtime(::Type{R}, plan::PL, cursor::CU, context::C, wiring::W, process::P, lifetime::LT) where {R, PL, CU, C, W, P, LT} =
    _next_runtime_type(R, Core.Compiler.return_type(_probe_step, Tuple{PL, CU, LoopContext{C, R}, W, P, LT}))

"""Whether the declared locals of two runtime context types have the same types."""
_same_locals(::Type{A}, ::Type{B}) where {A, B} = _local_data_type(A) === _local_data_type(B)
_same_locals(::Type{A}, ::Type{Nothing}) where {A} = false

"""
    _settle_runtime(plan, cursor, context, runtimecontext, wiring, process, lifetime)

The runtime context the loop starts with, typed before the first step (see the note above). All of it is resolved while
the run is compiled; nothing of it runs per step.

1. Untyped declared locals become probes; inference runs one step and reads off what is written to each local and
   what is returned as an output. The locals get their types, the outputs typed slots.
2. A second round, with these types, checks the rule that a declared local keeps its type after its first value
   (an error otherwise, naming the step). It can still widen an output slot: an output computed from a local
   (`v = f(y)`) is only known once the local's type is.
3. If it did, a third round must not change anything. If the outputs do not settle, or inference cannot tell, the
   outputs get no slots and take their types as written, as before.
"""
@inline function _settle_runtime(plan, cursor, context, runtimecontext::RC, wiring, process, lifetime) where {RC<:ProcessContext}
    step = (plan, cursor, context, wiring, process, lifetime)
    untyped = _has_untyped_locals(RC)
    no_writes_seen = _probe_runtime_type(RC)
    first_round = _widen_runtime(no_writes_seen, step...)
    if first_round === Nothing
        untyped && _local_type_error(no_writes_seen, false, step...)
        return runtimecontext
    end
    second_round = _widen_runtime(first_round, step...)
    untyped && !_same_locals(first_round, second_round) && _local_type_error(first_round, true, step...)
    settled = second_round === first_round ? first_round :
        second_round === Nothing ? Nothing :
        _widen_runtime(second_round, step...) === second_round ? second_round : Nothing
    settled === Nothing && return untyped ? (@inline _settled_runtime(runtimecontext, _without_outputs(first_round))) : runtimecontext
    return @inline _settled_runtime(runtimecontext, settled)
end

_without_outputs(::Type{R}) where {R<:ProcessContext} = _drop_parts(R, (:_captured_returns, :_subcontext_returns))
function _drop_parts(::Type{RC}, drop) where {RC<:ProcessContext}
    D = fieldtype(RC, :subcontexts)
    keep = [i for (i, n) in enumerate(fieldnames(D)) if !(n in drop)]
    return ProcessContext{NamedTuple{Tuple(fieldnames(D)[keep]), Tuple{fieldtypes(D)[keep]...}}, fieldtype(RC, :reg)}
end

"""A value of slots type `T` (a named tuple, possibly of named tuples) with every slot `nothing`."""
_empty_slots_expr(::Type{T}) where {T<:NamedTuple} =
    :($T(($((fieldtype(T, n) <: NamedTuple ? _empty_slots_expr(fieldtype(T, n)) : :nothing for n in fieldnames(T))...),)))

"""`runtimecontext` with the types of `R`: untyped locals as unset `Maybe`s of their type, and output slots set to `nothing`."""
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
