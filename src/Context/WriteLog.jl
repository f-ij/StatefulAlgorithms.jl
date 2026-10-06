#=
EXPERIMENTAL: finding which persistent fields a step can write, by type inference.

A loop carries only the fields its steps can write (Carry.jl). To know them, `_written_fields` asks inference what
`_step!` returns for a context whose registry slot is a `WriteLog`. Every persistent write ends in
`merge_into_subcontext_rebuild` or `withsubcontexts`; for a logged context those add the written
`(subcontext, field)` pairs to the log's type. The inferred return type then lists every field any branch of the
step can write: children on intervals, routines and the interactive `ContextExchange` included. Nothing runs: the
question is answered while the loop is compiled.
=#

"""
    WriteLog{R,W}

Registry slot of a logged context: the registry `reg`, plus in `W` the persistent fields written so far, as a sorted
tuple of `(subcontext, field)` pairs. Only the context's type changes; its layout and values are those of the
ordinary context.
"""
struct WriteLog{R,W}
    reg::R
end

@inline registryref(pc::ProcessContext{D,<:WriteLog}) where {D} = getfield(getfield(pc, :reg), :reg)
@inline getregistrytype(::Type{<:ProcessContext{D,WriteLog{R,W}}}) where {D,R,W} = getregistrytype(ProcessContext{D,R})

"""The context type without its write log (the type itself for an ordinary context)."""
_unlogged(::Type{ProcessContext{D,WriteLog{R,W}}}) where {D,R,W} = ProcessContext{D,R}
_unlogged(T::Type) = T

"""The context type with an empty write log, for an ordinary or a logged context type."""
_empty_logged(::Type{ProcessContext{D,WriteLog{R,W}}}) where {D,R,W} = ProcessContext{D,WriteLog{R,()}}
_empty_logged(::Type{ProcessContext{D,R}}) where {D,R} = ProcessContext{D,WriteLog{R,()}}

"""`pc` with an empty write log around its registry."""
@inline function with_empty_log(pc::ProcessContext)
    L = _empty_logged(typeof(pc))
    return L(get_subcontexts(pc), fieldtype(L, :reg)(registryref(pc)))
end

"""`pc` without its write log (`pc` itself for an ordinary context)."""
@inline without_log(pc::ProcessContext{D,WriteLog{R,W}}) where {D,R,W} = ProcessContext{D,R}(get_subcontexts(pc), registryref(pc))
@inline without_log(pc::ProcessContext) = pc

"""
The context a plan hands a child: a logged context with its log emptied (any other context unchanged). Together
with `with_child_log` this gives every child, at every level of a nested plan, the same context type, as without
logs. A type that grows from parent to child (the log of the siblings before it) makes inference stop inlining
nested plans at its recursion limit.
"""
@inline child_context(pc::ProcessContext{D,<:WriteLog}) where {D} = @inline with_empty_log(pc)
@inline child_context(context::C) where {C} = context

"""The child's result `stepped` with the log of `parent` added (`stepped` itself when `parent` has no log)."""
@inline @generated function with_child_log(parent::ProcessContext{D,WriteLog{R,W}}, stepped::ProcessContext{D2,WriteLog{R,W2}}) where {D,R,W,D2,W2}
    W3 = _union_written(W, W2)
    return :(ProcessContext{D2,WriteLog{R,$W3}}(get_subcontexts(stepped), WriteLog{R,$W3}(registryref(stepped))))
end
@inline with_child_log(parent::P, stepped::S) where {P,S} = stepped

"""`W` and `new` as one sorted tuple of `(subcontext, field)` pairs without repeats."""
_union_written(W::Tuple, new::Tuple) = Tuple(sort!(unique!(Any[W..., new...]); by = string))

"""A logged context with `subcontexts`, whose log also holds the `(subcontext, field)` pairs in `New`."""
@inline @generated function _log_writes(pc::ProcessContext{D,WriteLog{R,W}}, subcontexts::D2, ::Val{New}) where {D,R,W,D2,New}
    W2 = _union_written(W, New)
    return :(ProcessContext{D2,WriteLog{R,$W2}}(subcontexts, WriteLog{R,$W2}(registryref(pc))))
end

# Merging fields into one subcontext logs exactly those fields.
@inline @generated function merge_into_subcontext_rebuild(pc::ProcessContext{D,WriteLog{R,W}}, ::Val{name}, args) where {D,R,W,name}
    New = Tuple((name, f) for f in fieldnames(args))
    return quote
        old_subcontexts = @inline get_subcontexts(pc)
        new_subcontext = @inline merge(getproperty(old_subcontexts, $(QuoteNode(name))), args)
        new_subcontexts = @inline replace_namedtuple_field(old_subcontexts, Val($(QuoteNode(name))), new_subcontext)
        return @inline _log_writes(pc, new_subcontexts, Val($New))
    end
end

# Replacing subcontexts as a whole logs every field of every subcontext: which ones changed is not known.
@inline @generated function withsubcontexts(pc::ProcessContext{D,WriteLog{R,W}}, subcontexts::D2) where {D,R,W,D2<:NamedTuple}
    New = Tuple((s, f) for s in fieldnames(D2) for f in fieldnames(getdatatype(fieldtype(D2, s))))
    return :(@inline _log_writes(pc, subcontexts, Val($New)))
end

"""
    _written_fields(algo, cursor, context, runtimecontext, wiring, namespace, process, lifetime)

`Val(W)` with `W` the persistent fields, as `(subcontext, field)` pairs, that `_step!` with these arguments can
write, or `nothing` when that cannot be determined. The arguments are those of the `_step!` call; only the context's
type matters, and it may be ordinary or logged.

A compile-time constant: `Core.Compiler.return_type` is evaluated by inference while the caller is compiled, and the
rest folds. The question is asked for the context with an empty log, which is the type a carrying loop steps with
(`step_context`, Carry.jl), so it reuses the inference of the step that is compiled anyway.
"""
@inline function _written_fields(algo::A, cursor::S, context::C, runtimecontext::RC, wiring::W, namespace::N,
                                 process::P, lifetime::LT) where {A,S,C<:ProcessContext,RC,W,N,P,LT}
    L = _empty_logged(C)
    return _written_from_return_type(Core.Compiler.return_type(_step!, Tuple{A,S,L,RC,W,N,P,LT}), L)
end

"""
`Val(W)` from the inferred return type `rt` of a step given the empty-logged context type `L`: `W` holds every field
logged on any branch (branches that write different fields give a `Union`). `nothing` unless every possible return
is `(context, runtime context)` with the context being `L` with some log.
"""
Base.@assume_effects :foldable function _written_from_return_type(@nospecialize(rt), @nospecialize(L))
    rt === Union{} && return nothing                 # the step always throws: nothing can be concluded
    written = ()
    for T in Base.uniontypes(rt)
        (T isa DataType && T <: Tuple && length(T.parameters) == 2) || return nothing
        for C in Base.uniontypes(T.parameters[1])
            logged = _logged_writes(C, L)
            isnothing(logged) && return nothing
            written = _union_written(written, logged)
        end
    end
    return Val(written)
end

"""The writes logged in the context type `C`, or `nothing` unless `C` is the empty-logged type `L` with some log."""
_logged_writes(::Type{ProcessContext{D,WriteLog{R,W}}}, ::Type{ProcessContext{D,WriteLog{R,()}}}) where {D,R,W} = W
_logged_writes(@nospecialize(C), @nospecialize(L)) = nothing
