#=
EXPERIMENTAL: finding which persistent fields a step can write, by type inference.

The loop carries only the fields a step can write (see `_run_steps` in Loops.jl). To know them, `_written_fields`
infers `_step!` once with a context whose registry slot is a `WriteLog`. Every persistent write ends in
`merge_into_subcontext_rebuild` or `withsubcontexts`; for a logged context those add the written
`(subcontext, field)` pairs to the log's type. The inferred return type then lists every field any branch of the
step can write: children on intervals, routines and the interactive `ContextExchange` included. Nothing runs, and
it happens while the loop is compiled: a logged context only exists during inference.
=#

"""
    WriteLog{R,W}

Registry slot of a context that exists only during inference: the registry `reg`, plus in `W` the persistent
fields written so far, as a sorted tuple of `(subcontext, field)` pairs.
"""
struct WriteLog{R,W}
    reg::R
end

@inline registryref(pc::ProcessContext{D,<:WriteLog}) where {D} = getfield(getfield(pc, :reg), :reg)
@inline getregistrytype(::Type{<:ProcessContext{D,WriteLog{R,W}}}) where {D,R,W} = getregistrytype(ProcessContext{D,R})

"""The context type without its write log (the type itself for an ordinary context)."""
_unlogged(::Type{ProcessContext{D,WriteLog{R,W}}}) where {D,R,W} = ProcessContext{D,R}
_unlogged(T::Type) = T

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
    _written_fields(step_plan, step_cursor, context, runtimecontext, step_wiring, process, lifetime)

`Val(W)` with `W` the persistent fields, as `(subcontext, field)` pairs, that one step of `step_plan` can write, or
`nothing` when that cannot be determined. A compile-time constant: `Core.Compiler.return_type` is evaluated by
inference while the caller is compiled, and the rest folds.
"""
@inline function _written_fields(step_plan::SP, step_cursor::SC, context::ProcessContext{D,R}, runtimecontext::RC,
                                 step_wiring::W, process::P, lifetime::LT) where {SP,SC,D,R,RC,W,P,LT}
    logged_step = Tuple{SP, SC, ProcessContext{D,WriteLog{R,()}}, RC, W, Namespace{nothing}, P, LT}
    return _written_from_return_type(Core.Compiler.return_type(_step!, logged_step), D, R)
end

"""
`Val(W)` from the inferred return type of a logged step: `W` holds every field logged on any branch (branches that
write different fields give a `Union`). `nothing` unless every possible return is `(context, runtime context)` with
the context being the step's own context type with a log.
"""
Base.@assume_effects :foldable function _written_from_return_type(@nospecialize(rt), @nospecialize(D), @nospecialize(R))
    rt === Union{} && return nothing                 # the step always throws: nothing can be concluded
    written = ()
    for T in Base.uniontypes(rt)
        (T isa DataType && T <: Tuple && length(T.parameters) == 2) || return nothing
        for C in Base.uniontypes(T.parameters[1])
            logged = _logged_writes(C, D, R)
            isnothing(logged) && return nothing
            written = _union_written(written, logged)
        end
    end
    return Val(written)
end

"""The writes logged in the context type `C`, or `nothing` unless `C` has subcontexts `D` and a log around registry `R`."""
_logged_writes(::Type{ProcessContext{D,WriteLog{R,W}}}, ::Type{D}, ::Type{R}) where {D,R,W} = W
_logged_writes(@nospecialize(C), @nospecialize(D), @nospecialize(R)) = nothing

"""
    _written_values(context, Val(W))

The values of the fields `W` in `context`, as `(; subcontext = (; field = value, ...), ...)`: the shape
`merge_into_subcontexts` takes.
"""
@inline @generated function _written_values(context::ProcessContext, ::Val{W}) where {W}
    subs = Tuple(unique(first.(W)))
    entries = map(subs) do s
        fields = Tuple(f for (s2, f) in W if s2 === s)
        values = [:(getfield(getdata(getfield(subcontexts, $(QuoteNode(s)))), $(QuoteNode(f)))) for f in fields]
        :(NamedTuple{$fields}(($(values...),)))
    end
    return quote
        subcontexts = @inline get_subcontexts(context)
        return NamedTuple{$subs}(($(entries...),))
    end
end
