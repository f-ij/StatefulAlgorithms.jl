#=
EXPERIMENTAL: finding which persistent fields a step can write, by type inference.

The loop carries only the fields a step can write (see `_run_steps` in Loops.jl). To know them, `_written_fields`
infers `_step!` once with a context whose registry slot is a `WriteLog`. Every persistent write ends in
`merge_into_subcontext_rebuild` or `withsubcontexts`; for a logged context those add the written
`(subcontext, field)` pairs to the log's type. The inferred return type then lists every field any branch of the
step can write: children on intervals, routines and the interactive `ContextExchange` included. Nothing runs; a
logged context only exists during inference.
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

const _WRITTEN_FIELDS = Dict{Any,Any}()
const _WRITTEN_FIELDS_LOCK = ReentrantLock()

"""
    _written_fields(step_plan, step_cursor, context, runtimecontext, step_wiring, process, lifetime)

`Val(W)` with `W` the persistent fields, as `(subcontext, field)` pairs, that one step of `step_plan` can write;
`nothing` when that cannot be determined. Found by inferring `_step!` with a logged context (see the top of this
file) and cached per argument types.
"""
function _written_fields(step_plan, step_cursor, context::ProcessContext{D,R}, runtimecontext, step_wiring, process, lifetime) where {D,R}
    argtypes = Tuple{typeof(step_plan), typeof(step_cursor), ProcessContext{D,WriteLog{R,()}}, typeof(runtimecontext),
                     typeof(step_wiring), Namespace{nothing}, typeof(process), typeof(lifetime)}
    lock(_WRITTEN_FIELDS_LOCK) do
        get!(_WRITTEN_FIELDS, argtypes) do
            rt = try
                Base.infer_return_type(_step!, argtypes)
            catch
                Any
            end
            _written_from_return_type(rt, D, R)
        end
    end
end

"""
`Val(W)` from the inferred return type of a logged step: `W` is every field written on any branch. `nothing` unless
the return type is `(context, runtime context)` where each possible context type is the same context with a log
(branches that write different fields give a `Union` of such types).
"""
function _written_from_return_type(@nospecialize(rt), @nospecialize(D), @nospecialize(R))
    rt isa Union && return _written_union(Base.uniontypes(rt), D, R)
    (rt isa DataType && rt <: Tuple && length(rt.parameters) == 2) || return nothing
    return _written_union(Base.uniontypes(rt.parameters[1]), D, R)
end

"""`Val(W)` with `W` the union of the logs of the context types `Cs` (or the first elements of tuple types), or `nothing`."""
function _written_union(Cs::Vector, @nospecialize(D), @nospecialize(R))
    W = ()
    for C in Cs
        C isa DataType && C <: Tuple && length(C.parameters) == 2 && (C = C.parameters[1])
        (C isa DataType && C <: ProcessContext && C.parameters[1] === D) || return nothing
        L = C.parameters[2]
        (L isa DataType && L <: WriteLog && L.parameters[1] === R) || return nothing
        W = _union_written(W, L.parameters[2])
    end
    return Val(W)
end

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
