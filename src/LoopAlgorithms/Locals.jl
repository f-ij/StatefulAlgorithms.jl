export Local

"""
    Local(; name = initial_value, ...)

Declare loop-local variables on a plan, like `local x = 0` before a Julia `for` loop.

Pass it to `CompositeAlgorithm(...)` or `Routine(...)` like a route. The variables
are created when a run starts, every child can read them by name, and a child
updates one by returning that name. The initial value fixes the type: returned
values are converted to it, so the carried context never changes shape. With
`name = undef` the first value written fixes the type instead. They are
visible to `finalstep` and kept across pause/resume, but not stored after the run.

Sharing a value between children or across steps means declaring it here;
undeclared step returns are not meant to outlive the step that produced them.

Currently all declarations in a plan tree are run-level (created once per run),
including ones on nested plans.
"""
struct Local{NT<:NamedTuple} <: AbstractOption
    values::NT
    Local{NT}(values::NT) where {NT<:NamedTuple} = new{NT}(values)
end

Local(; values...) = Local(NamedTuple(values))

# A field declared `Union{Nothing,T}` is stored as `Maybe{T}`: a flag plus a value. A Julia
# Union field in the carried context blocks keeping it in registers (stack copies every step);
# `Maybe` keeps it registerizable, and reads turn it back into `nothing` or the value.
Local(values::NT) where {NT<:NamedTuple} = Local{_local_storage_type(NT)}(_local_storage(values))

"""
Flag-plus-value storage for a local that may not hold a value yet; `value` is undefined
while unset. `Empty` is what an unset local reads as: `Nothing` (reads give `nothing`) or
`UndefInitializer` (reads throw `UndefRefError`).
"""
struct Maybe{T, F<:Unsigned, Empty}
    isset::F      # as wide as T's alignment: a 1-byte Bool would leave padding that gets copied every step
    value::T
    Maybe{T, F, Empty}() where {T, F, Empty} = new{T, F, Empty}(zero(F))
    Maybe{T, F, Empty}(x) where {T, F, Empty} = new{T, F, Empty}(one(F), x)
end
maybe_type(::Type{T}, ::Type{Empty}) where {T, Empty} = Maybe{T, _maybe_flagtype(T), Empty}
_maybe_flagtype(::Type{T}) where {T} = (a = Base.datatype_alignment(T); a >= 8 ? UInt64 : a == 4 ? UInt32 : a == 2 ? UInt16 : UInt8)
Base.convert(::Type{Maybe{T, F, Empty}}, ::Empty) where {T, F, Empty} = Maybe{T, F, Empty}()
Base.convert(::Type{Maybe{T, F, Empty}}, x) where {T, F, Empty} = Maybe{T, F, Empty}(convert(T, x))
Base.convert(::Type{M}, m::M) where {M<:Maybe} = m

_throw_undef() = throw(UndefRefError())
@inline subcontext_view_value(m::Maybe{T, F, Nothing}, view::V) where {T, F, V<:SubContextView} =
    !iszero(getfield(m, :isset)) ? subcontext_view_value(getfield(m, :value), view) : nothing
@inline subcontext_view_value(m::Maybe{T, F, UndefInitializer}, view::V) where {T, F, V<:SubContextView} =
    !iszero(getfield(m, :isset)) ? subcontext_view_value(getfield(m, :value), view) : _throw_undef()
# A local that nothing ever writes keeps its declared `undef`.
@inline subcontext_view_value(::UndefInitializer, view::V) where {V<:SubContextView} = _throw_undef()

#=
`Local(x = undef)` and `Local(x = nothing)` declare a local without giving its type, like
`local x` or `x = nothing` before a Julia loop. As in Julia, the type comes from every value
written to it, found by inference before the run starts (`_settle_locals`), so the local
has its final type from the first step: `undef` becomes `Maybe{T,F,UndefInitializer}` (reads
see a `T`, or throw before the first write), `nothing` becomes `Maybe{T,F,Nothing}` (reads
see `Union{Nothing,T}`). Values written with different types are promoted to one type.
=#

"""Inference-only stand-in for an untyped local while its type is worked out; never constructed."""
struct LocalProbe{T, Empty} end
@inline subcontext_view_value(::LocalProbe{T, UndefInitializer}, view::V) where {T, V<:SubContextView} =
    T === Union{} ? _throw_undef() : _probe_value(T)
@inline subcontext_view_value(::LocalProbe{T, Nothing}, view::V) where {T, V<:SubContextView} = _probe_value(Union{Nothing, T})
_probe_value(::Type{T}) where {T} = Base.inferencebarrier(nothing)::T

"""Inference only: a write to a probe records the written type and keeps the field a probe."""
@generated _probe_write(::LocalProbe{T, Empty}, ::V) where {T, Empty, V} = :($(LocalProbe{_join_written(T, V, Empty), Empty}()))
function _join_written(T, V, Empty)
    Empty === Nothing && (V = Base.typesplit(V, Nothing))   # writing `nothing` to a `nothing` local is always allowed
    V === Union{} && return T
    return T === Union{} ? V : promote_type(T, V)
end

_is_untyped_local(::Type{T}) where {T} = T === UndefInitializer || T === Nothing

"""Runtime context type with every untyped local replaced by a probe that has seen no writes."""
@generated function _probe_runtime_type(::Type{RC}) where {RC<:ProcessContext}
    return _replace_local_types(RC) do name, T
        _is_untyped_local(T) ? LocalProbe{Union{}, T} : T
    end
end

"""Probe types widened by the values a step can write (`RT`: inferred `_step!` return type)."""
@generated function _next_probe_type(::Type{RC}, ::Type{RT}) where {RC<:ProcessContext, RT}
    # The runtime contexts a step can return: `RT` is `Tuple{context, runtimecontext}`, or a
    # union of those, and the runtime context part can itself be a union.
    tuples = RT === Union{} ? () : Base.uniontypes(RT)
    all(R -> R <: Tuple && fieldcount(R) == 2, tuples) ||
        return :(error("Could not infer the step of this plan (got $($RT)); declare the types of its `undef`/`nothing` locals."))
    returned = unique(Iterators.flatten(Base.uniontypes(fieldtype(R, 2)) for R in tuples))
    all(R -> R isa DataType && R <: ProcessContext, returned) ||
        return :(error("Could not infer the step of this plan (got $($RT)); declare the types of its `undef`/`nothing` locals."))
    return _replace_local_types(RC) do name, P
        P <: LocalProbe || return P
        T, Empty = P.parameters
        for R in returned
            W = fieldtype(_local_data_type(R), name)
            T = _join_written(T, W <: LocalProbe ? W.parameters[1] : W, Empty)
        end
        return LocalProbe{T, Empty}
    end
end

_local_data_type(::Type{RC}) where {RC<:ProcessContext} = fieldtype(fieldtype(fieldtype(RC, :subcontexts), :_local), :data)

"""`RC` with each field type of its `_local` subcontext data replaced by `f(name, type)`."""
function _replace_local_types(f, ::Type{RC}) where {RC<:ProcessContext}
    D = fieldtype(RC, :subcontexts)
    :_local in fieldnames(D) || return RC
    L = _local_data_type(RC)
    newL = NamedTuple{fieldnames(L), Tuple{(f(n, fieldtype(L, n)) for n in fieldnames(L))...}}
    newD = NamedTuple{fieldnames(D), Tuple{(n === :_local ? SubContext{:_local, newL} : fieldtype(D, n) for n in fieldnames(D))...}}
    return ProcessContext{newD, fieldtype(RC, :reg)}
end

@inline _probe_step(plan, cursor, context, runtimecontext, wiring, process, lifetime) =
    _step!(plan, cursor, context, runtimecontext, wiring, Namespace{nothing}(), process, lifetime)

"""
Give every local declared `undef` or `nothing` its final type before the run. The types
come from inference of one step (all branches, so a write that only happens later is
included), repeated until they stop changing so a local written from its own value
(`x = f(x)`) is typed too. Folded at compile time; nothing of it runs per step.
"""
@inline function _settle_locals(plan::PL, cursor::CU, context::C, runtimecontext::RC, wiring::W, process::P, lifetime::LT) where {PL, CU, C, RC<:ProcessContext, W, P, LT}
    _has_untyped_locals(RC) || return runtimecontext
    R1 = _probe_runtime_type(RC)
    R2 = _next_probe_type(R1, Core.Compiler.return_type(_probe_step, Tuple{PL, CU, C, R1, W, P, LT}))
    R3 = _next_probe_type(R2, Core.Compiler.return_type(_probe_step, Tuple{PL, CU, C, R2, W, P, LT}))
    R4 = _next_probe_type(R3, Core.Compiler.return_type(_probe_step, Tuple{PL, CU, C, R3, W, P, LT}))
    R4 === R3 || error("The types of this plan's `undef`/`nothing` locals do not settle; declare their types.")
    return @inline with_subcontext(runtimecontext, Val(:_local), SubContext{:_local}(_settled_locals(getlocals(runtimecontext), R4)))
end

@generated function _has_untyped_locals(::Type{RC}) where {RC<:ProcessContext}
    :_local in fieldnames(fieldtype(RC, :subcontexts)) || return false
    return any(_is_untyped_local, fieldtypes(_local_data_type(RC)))
end

"""The initial locals with each untyped one replaced by an unset `Maybe` of its settled type."""
@generated function _settled_locals(locals::NT, ::Type{R}) where {NT<:NamedTuple, R<:ProcessContext}
    L = _local_data_type(R)
    values = map(fieldnames(NT)) do name
        P = fieldtype(L, name)
        P <: LocalProbe || return :(getfield(locals, $(QuoteNode(name))))
        T, Empty = P.parameters
        T === Union{} && return :(getfield(locals, $(QuoteNode(name))))   # never written
        isconcretetype(T) || return :(error($("Local `$name` is written with values of type $T, which is not concrete; declare its type.")))
        return :($(maybe_type(T, Empty))())
    end
    return :(NamedTuple{$(fieldnames(NT))}(($(values...),)))
end

_storage_fieldtype(::Type{T}) where {T} = (T isa Union && Nothing <: T && T !== Nothing) ? maybe_type(Base.typesplit(T, Nothing), Nothing) : T
@generated _local_storage_type(::Type{NT}) where {NT<:NamedTuple} =
    :(NamedTuple{$(fieldnames(NT)), Tuple{$(map(_storage_fieldtype, fieldtypes(NT))...)}})
@inline _local_storage(values::NT) where {NT<:NamedTuple} =
    _local_storage_type(NT)(map((T, v) -> convert(T, v), fieldtypes(_local_storage_type(NT)), Tuple(values)))

"""Return the declared initial values carried by a `Local`."""
@inline getvalues(l::Local) = getfield(l, :values)

"""All `Local` declarations among `options`, merged into one named tuple of initial values."""
@inline declared_locals(options::Tuple{}) = (;)
@inline declared_locals(options::Tuple) = merge(_local_values(first(options)), declared_locals(Base.tail(options)))
@inline _local_values(l::Local) = getvalues(l)
@inline _local_values(::Any) = (;)

"""`options` plus a `Local` that rebuilds the plan wiring's declarations (for plan edits)."""
_with_local_options(options::Tuple, wiring::PlanWiring) =
    isempty(getfield(wiring, :locals)) ? options : (options..., Local{typeof(getfield(wiring, :locals))}(getfield(wiring, :locals)))

"""
Name of a local's slot in the runtime `_local` subcontext. A local declared on the root
plan keeps its name; one declared on a nested plan is suffixed with that plan's position.
"""
# `path` is the plan's position, e.g. "1.2"; a `String` so the resolver's recursion keeps one type.
local_storage_name(name::Symbol, path::String) = isempty(path) ? name : Symbol(name, "@", path)

"""Locals visible at a plan node: the inherited ones, shadowed by the node's own (names from the type, not the value)."""
_visible_locals(inherited::NamedTuple, ::NamedTuple{()}, path::String) = inherited
_visible_locals(inherited::NamedTuple, ::NamedTuple{names}, path::String) where {names} =
    merge(inherited, NamedTuple{names}(map(name -> local_storage_name(name, path), names)))

"""
Initial values of every local declared in a plan tree, keyed by storage name: the
memory for all of them is allocated in `_local` when a run starts.
"""
@generated function _tree_locals(plan::P) where {P<:AbstractPlan}
    names = Symbol[]
    values = Any[]
    function collect!(::Type{T}, expr, path) where {T}
        for name in fieldnames(fieldtype(fieldtype(T, :wiring), :locals))
            push!(names, local_storage_name(name, join(path, ".")))
            push!(values, :(getfield(getfield(getfield($expr, :wiring), :locals), $(QuoteNode(name)))))
        end
        F = fieldtype(T, :funcs)
        for i in 1:fieldcount(F)
            fieldtype(F, i) <: AbstractPlan && collect!(fieldtype(F, i), :(getfield(getfield($expr, :funcs), $i)), (path..., i))
        end
    end
    collect!(P, :plan, ())
    return :(NamedTuple{$(Tuple(names))}(($(values...),)))
end

"""Initial values of the locals declared on a loop algorithm's plan tree."""
@inline declared_locals(la::LoopAlgorithm) = _tree_locals(getplan(la))
@inline declared_locals(fa::FinalizedAlgorithm) = declared_locals(inneralgorithm(fa))
@inline declared_locals(::Any) = (;)

"""
Write returned values into the declared locals, keeping every field's declared type
(like a typed Julia local): values are converted, and a `Union{Nothing,T}` field stays a union.
"""
@inline @generated function _merge_declared(old::NT, args::A) where {NT<:NamedTuple, A<:NamedTuple}
    values = map(fieldnames(NT)) do name
        !(name in fieldnames(A)) && return :(getfield(old, $(QuoteNode(name))))
        fieldtype(NT, name) <: LocalProbe && return :(_probe_write(getfield(old, $(QuoteNode(name))), getfield(args, $(QuoteNode(name)))))
        return :(convert($(fieldtype(NT, name)), getfield(args, $(QuoteNode(name)))))
    end
    return :(NamedTuple{$(fieldnames(NT))}(($(values...),)))
end
