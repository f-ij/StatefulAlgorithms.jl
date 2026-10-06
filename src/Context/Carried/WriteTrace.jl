#=
EXPERIMENTAL: finding which persistent fields a step can write, by type inference.

A loop carries only the fields its steps can write (Carry.jl). To know them, `_written_fields` asks inference what
`_step!` returns for a context whose registry slot is a `WriteTrace`. Every persistent write ends in
`merge_into_subcontext_rebuild` or `withsubcontexts`; for a traced context those add the written
`(subcontext, field)` pairs to the trace's type. The inferred return type then lists every field any branch of the
step can write: children on intervals, routines and the interactive `ContextExchange` included. Nothing runs: the
question is answered while the loop is compiled.
=#

"""
    WriteTrace{R,W}

Registry slot of a traced context: the registry `reg`, plus in `W` the persistent fields written so far, as a sorted
tuple of `(subcontext, field)` pairs. Only the context's type changes; its layout and values are those of the
ordinary context.
"""
struct WriteTrace{R,W}
    reg::R
end

@inline registryref(pc::ProcessContext{D,<:WriteTrace}) where {D} = getfield(getfield(pc, :reg), :reg)
@inline getregistrytype(::Type{<:ProcessContext{D,WriteTrace{R,W}}}) where {D,R,W} = getregistrytype(ProcessContext{D,R})

"""The context type without its write trace (the type itself for an ordinary context)."""
_untraced(::Type{ProcessContext{D,WriteTrace{R,W}}}) where {D,R,W} = ProcessContext{D,R}
_untraced(T::Type) = T

"""The context type with an empty write trace, for an ordinary or a traced context type."""
_empty_traced(::Type{ProcessContext{D,WriteTrace{R,W}}}) where {D,R,W} = ProcessContext{D,WriteTrace{R,()}}
_empty_traced(::Type{ProcessContext{D,R}}) where {D,R} = ProcessContext{D,WriteTrace{R,()}}

"""`pc` with an empty write trace around its registry."""
@inline function with_empty_trace(pc::ProcessContext)
    L = _empty_traced(typeof(pc))
    return L(get_subcontexts(pc), fieldtype(L, :reg)(registryref(pc)))
end

"""`pc` without its write trace (`pc` itself for an ordinary context)."""
@inline without_trace(pc::ProcessContext{D,WriteTrace{R,W}}) where {D,R,W} = ProcessContext{D,R}(get_subcontexts(pc), registryref(pc))
@inline without_trace(pc::ProcessContext) = pc

"""
The context a plan hands a child: a traced context with its trace emptied (any other context unchanged). Together
with `with_child_trace` this gives every child, at every level of a nested plan, the same context type, as without
traces. A type that grows from parent to child (the trace of the siblings before it) makes inference stop inlining
nested plans at its recursion limit.
"""
@inline child_context(pc::ProcessContext{D,<:WriteTrace}) where {D} = @inline with_empty_trace(pc)
@inline child_context(context::C) where {C} = context

"""
The child's result `stepped` with the trace of `parent` added. When either has no trace, `stepped` itself: a child
whose result lost its trace makes the whole step untraced, so the loop carries the whole context.
"""
@inline @generated function with_child_trace(parent::ProcessContext{D,WriteTrace{R,W}}, stepped::ProcessContext{D2,WriteTrace{R,W2}}) where {D,R,W,D2,W2}
    W3 = _union_written(W, W2)
    return :(ProcessContext{D2,WriteTrace{R,$W3}}(get_subcontexts(stepped), WriteTrace{R,$W3}(registryref(stepped))))
end
@inline with_child_trace(parent::P, stepped::S) where {P,S} = stepped

"""`W` and `new` as one sorted tuple of `(subcontext, field)` pairs without repeats."""
_union_written(W::Tuple, new::Tuple) = Tuple(sort!(unique!(Any[W..., new...]); by = string))

"""A traced context with `subcontexts`, whose trace also holds the `(subcontext, field)` pairs in `New`."""
@inline @generated function _trace_writes(pc::ProcessContext{D,WriteTrace{R,W}}, subcontexts::D2, ::Val{New}) where {D,R,W,D2,New}
    W2 = _union_written(W, New)
    return :(ProcessContext{D2,WriteTrace{R,$W2}}(subcontexts, WriteTrace{R,$W2}(registryref(pc))))
end

# Merging fields into one subcontext traces exactly those fields.
@inline @generated function merge_into_subcontext_rebuild(pc::ProcessContext{D,WriteTrace{R,W}}, ::Val{name}, args) where {D,R,W,name}
    New = Tuple((name, f) for f in fieldnames(args))
    return quote
        old_subcontexts = @inline get_subcontexts(pc)
        new_subcontext = @inline merge(getproperty(old_subcontexts, $(QuoteNode(name))), args)
        new_subcontexts = @inline replace_namedtuple_field(old_subcontexts, Val($(QuoteNode(name))), new_subcontext)
        return @inline _trace_writes(pc, new_subcontexts, Val($New))
    end
end

# Replacing subcontexts as a whole traces every field of every subcontext: which ones changed is not known.
@inline @generated function withsubcontexts(pc::ProcessContext{D,WriteTrace{R,W}}, subcontexts::D2) where {D,R,W,D2<:NamedTuple}
    New = Tuple((s, f) for s in fieldnames(D2) for f in fieldnames(getdatatype(fieldtype(D2, s))))
    return :(@inline _trace_writes(pc, subcontexts, Val($New)))
end

"""
    _written_fields(algo, cursor, context, runtimecontext, wiring, namespace, process, lifetime)

`Val(W)` with `W` the persistent fields, as `(subcontext, field)` pairs, that `_step!` with these arguments can
write, or `nothing` when that cannot be determined. The arguments are those of the `_step!` call; only the context's
type matters, and it may be ordinary or traced.

A compile-time constant: `Core.Compiler.return_type` is evaluated by inference while the caller is compiled, and the
rest folds. The question is asked for the context with an empty trace, which is the type a carrying loop steps with
(`step_context`, Carry.jl), so it reuses the inference of the step that is compiled anyway.
"""
@inline function _written_fields(algo::A, cursor::S, context::C, runtimecontext::RC, wiring::W, namespace::N,
                                 process::P, lifetime::LT) where {A,S,C<:ProcessContext,RC,W,N,P,LT}
    L = _empty_traced(C)
    return _written_from_return_type(Core.Compiler.return_type(_step!, Tuple{A,S,L,RC,W,N,P,LT}), L)
end

"""
`Val(W)` from the inferred return type `rt` of a step given the empty-traced context type `L`: `W` holds every field
traced on any branch (branches that write different fields give a `Union`). `nothing` unless every possible return
is `(context, runtime context)` with the context being `L` with some trace.
"""
Base.@assume_effects :foldable function _written_from_return_type(@nospecialize(rt), @nospecialize(L))
    rt === Union{} && return nothing                 # the step always throws: nothing can be concluded
    written = ()
    for T in Base.uniontypes(rt)
        (T isa DataType && T <: Tuple && length(T.parameters) == 2) || return nothing
        for C in Base.uniontypes(T.parameters[1])
            traced = _traced_writes(C, L)
            isnothing(traced) && return nothing
            written = _union_written(written, traced)
        end
    end
    return Val(written)
end

"""The writes traced in the context type `C`, or `nothing` unless `C` is the empty-traced type `L` with some trace."""
_traced_writes(::Type{ProcessContext{D,WriteTrace{R,W}}}, ::Type{ProcessContext{D,WriteTrace{R,()}}}) where {D,R,W} = W
_traced_writes(@nospecialize(C), @nospecialize(L)) = nothing
