export Local, Declaration

#=
AI GENERATED
Declared locals: variables a plan declares for its children to share, like `local x` before a
Julia loop. A declaration lives on the plan that makes it (in its `PlanWiring`); the values live
in the runtime context's `_declared_locals` subcontext, one slot per declaration.

1. Declaring     `Local`, how declarations are collected and named
2. Storage       `Maybe`, for locals that may not hold a value yet, and the field types declared values are stored with
3. Reading and writing during a run
4. Typing locals declared without a type (no value, or `nothing`), before the run
   (the errors when that fails are in TypeErrors.jl)
=#

############################################################################################
# 1. Declaring
############################################################################################

"""
    Local(:x, :y => Float64, ...)

Declare loop-local variables on a plan without a value, like `local x` (and `local y::Float64`) before a Julia `for`
loop; what a DSL block's `local x` becomes. Pass it to `CompositeAlgorithm(...)` or `Routine(...)` like a route. A
name alone gets the type of what is written to it, worked out before the run (section 4); `name => T` has type `T`.
Reading a local before anything is written to it is an error. A local with a starting value is a
[`Declaration`](@ref).

- Scope: the declaring plan and everything below it; the nearest declaration of a name wins,
  and each copy of a plan has its own slot.
- Lifetime: one run. Created when the run starts, kept across pause/resume, not saved.
- Use: a child reads and writes a local only through a wire into it,
  `Route(:_declared_locals => Algo, :x => :x)`: it reads the local as `x`, and what it returns as `x` is written back
  through the wire. In a DSL block, a call reads the locals named in its arguments, and an assignment (`x = f()`)
  writes one.

Sharing a value between children or across steps means declaring it; undeclared step returns are not meant to outlive
the step that produced them.
"""
struct Local{NT<:NamedTuple} <: AbstractOption
    values::NT
    Local{NT}(values::NT) where {NT<:NamedTuple} = new{NT}(values)
end

Local(names::Union{Symbol, Pair{Symbol, <:Type}}...) = _build_local(NamedTuple(_declare_unset(name) for name in names))
_declare_unset(name::Symbol) = name => undef
_declare_unset((name, T)::Pair{Symbol, <:Type}) = name => make_maybe_type(T, UndefInitializer)()
Local(; values...) = error("`Local(", join(("$k = …" for k in keys(values)), ", "), ")`: a local is declared without a value, `Local(",
                           join((repr(k) for k in keys(values)), ", "), ")`. A starting value is a `Declaration(", join(("$k = …" for k in keys(values)), ", "), ")`.")

"""
    Declaration(x = value, ...)

Declare loop-local variables on a plan with a starting value: a [`Local`](@ref) whose slots hold `value` when the run
starts, and the type of `value` (returned values are converted to it; `nothing` is a value until the first write, and
then the type of what is written). For plans built with constructors; a DSL block declares locals without a value
(`local x`) and keeps a starting value in `@state`.
"""
Declaration(; values...) = Declaration(NamedTuple(values))
Declaration(values::NamedTuple) = _build_local(values)

"""Build a `Local` from declared values, stored with the field types the run will carry (section 2)."""
_build_local(values::NT) where {NT<:NamedTuple} = Local{_to_storage_types(NT)}(_convert_to_storage(values))

"""Return the declared initial values carried by a `Local`."""
@inline getvalues(l::Local) = getfield(l, :values)

"""Collect the `Local` declarations among one plan's `options`, merged into one named tuple of initial values keyed by their plain names."""
@inline collect_plan_locals(options::Tuple{}) = (;)
@inline collect_plan_locals(options::Tuple) = merge(_extract_locals(first(options)), collect_plan_locals(Base.tail(options)))
@inline _extract_locals(l::Local) = getvalues(l)
@inline _extract_locals(::T) where {T} = (;)

"""
Make the name of the slot of a declared local (in `_declared_locals`) or a captured return (in `_captured_returns`).
One of the root plan keeps its name; one of a nested plan is suffixed with that plan's position, `x@1.2` (see `Scope`).
`path` is the plan's position, e.g. "1.2"; a `String` so the resolver's recursion keeps one type.
"""
make_storage_name(name::Symbol, path::String) = isempty(path) ? name : Symbol(name, "@", path)

"""
Collect the initial values of every local declared in a plan tree, keyed by storage name: the
memory for all of them is allocated in `_declared_locals` when a run starts.
"""
@generated function collect_tree_locals(plan::P) where {P<:AbstractPlan}
    names = Symbol[]
    values = Any[]
    function collect!(::Type{T}, expr, path) where {T}
        for name in fieldnames(fieldtype(fieldtype(T, :wiring), :locals))
            push!(names, make_storage_name(name, join(path, ".")))
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
@inline collect_tree_locals(la::LoopAlgorithm) = collect_tree_locals(getplan(la))
@inline collect_tree_locals(fa::FinalizedAlgorithm) = collect_tree_locals(inneralgorithm(fa))
@inline collect_tree_locals(::T) where {T} = (;)

############################################################################################
# 2. Storage
############################################################################################

"""
Flag-plus-value storage for a local that may not hold a value yet; `value` is undefined while
unset. `Empty` is what an unset local reads as: `Nothing` (reads give `nothing`) or
`UndefInitializer` (reads throw `UndefRefError`).
"""
struct Maybe{T, F<:Unsigned, Empty}
    isset::F      # as wide as T's alignment: a 1-byte Bool would leave padding that gets copied every step
    value::T
    Maybe{T, F, Empty}() where {T, F, Empty} = new{T, F, Empty}(zero(F))
    Maybe{T, F, Empty}(x) where {T, F, Empty} = new{T, F, Empty}(one(F), x)
end
make_maybe_type(::Type{T}, ::Type{Empty}) where {T, Empty} = Maybe{T, _choose_flag_type(T), Empty}
_choose_flag_type(::Type{T}) where {T} = isconcretetype(T) ? (a = Base.datatype_alignment(T); a >= 8 ? UInt64 : a == 4 ? UInt32 : a == 2 ? UInt16 : UInt8) : UInt8
Base.convert(::Type{Maybe{T, F, Empty}}, ::Empty) where {T, F, Empty} = Maybe{T, F, Empty}()
Base.convert(::Type{Maybe{T, F, Empty}}, x) where {T, F, Empty} = Maybe{T, F, Empty}(convert(T, x))
Base.convert(::Type{M}, m::M) where {M<:Maybe} = m

# Declared values are stored with the field types the run will carry: a `Union{Nothing,T}`
# becomes a `Maybe` (a Julia `Union` field in the carried context costs copies every step).
_to_storage_type(::Type{T}) where {T} = (T isa Union && Nothing <: T && T !== Nothing) ? make_maybe_type(Base.typesplit(T, Nothing), Nothing) : T
@generated _to_storage_types(::Type{NT}) where {NT<:NamedTuple} =
    :(NamedTuple{$(fieldnames(NT)), Tuple{$(map(_to_storage_type, fieldtypes(NT))...)}})
@inline _convert_to_storage(values::NT) where {NT<:NamedTuple} =
    _to_storage_types(NT)(map((T, v) -> convert(T, v), fieldtypes(_to_storage_types(NT)), Tuple(values)))

############################################################################################
# 3. Reading and writing during a run
############################################################################################

# Reads: a `Maybe` reads as its value, or as `nothing` / an error while unset.
_throw_undef() = throw(UndefRefError())
@inline view_value(view::V, m::Maybe{T, F, Nothing}) where {T, F, V<:SubContextView} =
    !iszero(getfield(m, :isset)) ? view_value(view, getfield(m, :value)) : nothing
@inline view_value(view::V, m::Maybe{T, F, UndefInitializer}) where {T, F, V<:SubContextView} =
    !iszero(getfield(m, :isset)) ? view_value(view, getfield(m, :value)) : _throw_undef()
# A local declared without a value that no step ever writes keeps its `undef`.
@inline view_value(view::V, ::UndefInitializer) where {V<:SubContextView} = _throw_undef()

# Shown after the run (`final_context`): a `Maybe` shows as its value, or as `nothing` while unset.
@inline shown_value(m::Maybe) = iszero(getfield(m, :isset)) ? nothing : shown_value(getfield(m, :value))

"""Write a step's returns `args` into the locals `old`: converted to each local's type, or widening a probe (section 4)."""
@inline @generated function _write_locals(old::NT, args::A) where {NT<:NamedTuple, A<:NamedTuple}
    values = map(fieldnames(NT)) do name
        !(name in fieldnames(A)) && return :(getfield(old, $(QuoteNode(name))))
        fieldtype(NT, name) <: LocalProbe && return :(_record_probe_write(getfield(old, $(QuoteNode(name))), getfield(args, $(QuoteNode(name)))))
        return :(convert($(fieldtype(NT, name)), getfield(args, $(QuoteNode(name)))))
    end
    return :(NamedTuple{$(fieldnames(NT))}(($(values...),)))
end

############################################################################################
# 4. Typing locals declared without a type, before the run
############################################################################################

#=
A local declared without a value or as `nothing` has no type of its own. As in Julia, its type
is the type of every value written to it. That is found by inference before the first step
(`_runtime_context_typed_before_loop`, Outputs.jl), so the context has its final type from the start: a local without a value
becomes `Maybe{T,F,UndefInitializer}`, a `nothing` local `Maybe{T,F,Nothing}`. Values written with
different types are promoted to one type.

Everything here works on types, not values: a "probe" is a field *type* that stands in for such
a local while inference finds out what gets written to it.
=#

"""Inference-only stand-in for an untyped local while its type is worked out; never constructed."""
struct LocalProbe{T, Empty} end   # T: the local's type so far; Empty: `UndefInitializer` or `Nothing`, what it is before its first value
@inline view_value(view::V, ::LocalProbe{T, UndefInitializer}) where {T, V<:SubContextView} =
    T === Union{} ? _throw_undef() : _pretend_value(T)
@inline view_value(view::V, ::LocalProbe{T, Nothing}) where {T, V<:SubContextView} = _pretend_value(Union{Nothing, T})
"""Return a value that inference treats as being of type `T`."""
_pretend_value(::Type{T}) where {T} = Base.inferencebarrier(nothing)::T

"""
Inference only: record a write to a probe by widening the local's type with the written type; the field stays a
probe. A write of a type the local already has leaves the probe's type as it is, so a step that may or may not write
it (a child on a schedule) gives one type, not two.
"""
@generated _record_probe_write(::LocalProbe{T, Empty}, ::V) where {T, Empty, V} =
    :($(LocalProbe{_widen_local_type(T, V, Empty), Empty}()))
"""Widen the local type `T` with a written type `V`: `V` if nothing was written yet, else their promotion."""
function _widen_local_type(T, V, Empty)
    Empty === Nothing && (V = Base.typesplit(V, Nothing))   # writing `nothing` to a `nothing` local is always allowed
    V === Union{} && return T
    return T === Union{} ? V : promote_type(T, V)
end

_is_untyped_local(::Type{T}) where {T} = T === UndefInitializer || T === Nothing

"""Get the type of the `_declared_locals` data in runtime context type `RC`."""
_get_locals_type(::Type{RC}) where {RC<:ProcessContext} = fieldtype(fieldtype(fieldtype(RC, :subcontexts), :_declared_locals), :data)

"""`RC` with each field type of its `_declared_locals` subcontext data replaced by `f(name, type)`."""
function _replace_local_types(f, ::Type{RC}) where {RC<:ProcessContext}
    D = fieldtype(RC, :subcontexts)
    :_declared_locals in fieldnames(D) || return RC
    L = _get_locals_type(RC)
    newL = NamedTuple{fieldnames(L), Tuple{(f(n, fieldtype(L, n)) for n in fieldnames(L))...}}
    newD = NamedTuple{fieldnames(D), Tuple{(n === :_declared_locals ? SubContext{:_declared_locals, newL} : fieldtype(D, n) for n in fieldnames(D))...}}
    return ProcessContext{newD, fieldtype(RC, :reg)}
end

"""Replace every untyped local in runtime context type `RC` by a probe that has seen no writes."""
@generated function _insert_probes(::Type{RC}) where {RC<:ProcessContext}
    return _replace_local_types(RC) do name, T
        _is_untyped_local(T) ? LocalProbe{Union{}, T} : T
    end
end

"""
Widen the probes in context type `RC` by the types the step wrote to them, given the runtime context types one plan
step can return (`returned`). Used by `_runtime_context_type_with_step_writes` (Outputs.jl).
"""
function _widen_probes(::Type{RC}, returned) where {RC<:ProcessContext}
    return _replace_local_types(RC) do name, P
        P <: LocalProbe || return P
        T, Empty = P.parameters
        for R in returned
            W = fieldtype(_get_locals_type(R), name)
            T = _widen_local_type(T, W <: LocalProbe ? W.parameters[1] : W, Empty)
        end
        return LocalProbe{T, Empty}
    end
end

@generated function _has_untyped_locals(::Type{RC}) where {RC<:ProcessContext}
    :_declared_locals in fieldnames(fieldtype(RC, :subcontexts)) || return false
    return any(_is_untyped_local, fieldtypes(_get_locals_type(RC)))
end

"""Settle the initial locals: replace each untyped one by an unset `Maybe` of the type it settled on in `R`."""
@generated function _settle_locals(locals::NT, ::Type{R}) where {NT<:NamedTuple, R<:ProcessContext}
    L = _get_locals_type(R)
    values = map(fieldnames(NT)) do name
        P = fieldtype(L, name)
        P <: LocalProbe || return :(getfield(locals, $(QuoteNode(name))))
        T, Empty = P.parameters
        T === Union{} && return :(getfield(locals, $(QuoteNode(name))))   # never written
        isconcretetype(T) || return :(error($("Local `$name` is written with values of type $T, which is not concrete; declare its type.")))
        return :($(make_maybe_type(T, Empty))())
    end
    return :(NamedTuple{$(fieldnames(NT))}(($(values...),)))
end

include("TypeErrors.jl")
