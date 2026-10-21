export Local, Declaration

#=
AI GENERATED
Declared locals: variables a plan declares for its children to share, like `local x` before a
Julia loop. A declaration lives on the plan that makes it (in its `PlanWiring`); the values live
in the runtime context's `_declared_locals` subcontext, one slot per declaration.

1. Declaring     `Local`, how declarations are collected and named
2. Storage       the placeholders of locals without a value (`undef`, `UndefLocal{T}`), `Maybe` for a local that can
                 hold `nothing` or a value, and the field types declared values are stored with
3. Reading and writing during a run: the first write replaces a placeholder, and a local declared with a type converts
                 to it there

How the placeholders and a `Maybe` read and show (their hook methods) is in HookExtensions.jl.
=#

############################################################################################
# 1. Declaring
############################################################################################

"""
    Local(:x, :y => Float64, ...)

Declare loop-local variables on a plan without a value, like `local x` (and `local y::Float64`) before a Julia `for`
loop; what a DSL block's `local x` becomes. Pass it to `CompositeAlgorithm(...)` or `Routine(...)` like a route. A
name alone gets the type of its first value (section 3); `name => T` has type `T`.
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
_declare_unset((name, T)::Pair{Symbol, <:Type}) = name => UndefLocal{T}()
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
Collect the initial values of every local declared in a plan tree, keyed by storage name: the
memory for all of them is allocated in `_declared_locals` when a run starts.
"""
@generated function collect_tree_locals(plan::P) where {P<:AbstractPlan}
    names = Symbol[]
    values = Any[]
    function collect!(@nospecialize(T::Type), @nospecialize(expr), @nospecialize(path))   # compiled once, not per plan node type or depth
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
Placeholder of a local declared with type `T` and without a value (`local x::T`, `Local(:x => T)`): reading it throws
`UndefRefError`, and the first write replaces it with the value converted to `T` (section 3). A local declared without a
type has the placeholder `undef` instead.
"""
struct UndefLocal{T} end

"""
Flag-plus-value storage for a local that holds `nothing` or a value of type `T` (a `Union{Nothing,T}` local, or a
`nothing` local after its first value); `value` is undefined while the local holds `nothing`.
"""
struct Maybe{T, F<:Unsigned}
    isset::F      # as wide as T's alignment: a 1-byte Bool would leave padding that gets copied every step
    value::T
    Maybe{T, F}() where {T, F} = new{T, F}(zero(F))
    Maybe{T, F}(x) where {T, F} = new{T, F}(one(F), x)
end
make_maybe_type(::Type{T}) where {T} = Maybe{T, _choose_flag_type(T)}
_choose_flag_type(::Type{T}) where {T} = isconcretetype(T) ? (a = Base.datatype_alignment(T); a >= 8 ? UInt64 : a == 4 ? UInt32 : a == 2 ? UInt16 : UInt8) : UInt8
Base.convert(::Type{Maybe{T, F}}, ::Nothing) where {T, F} = Maybe{T, F}()
Base.convert(::Type{Maybe{T, F}}, x) where {T, F} = Maybe{T, F}(convert(T, x))
Base.convert(::Type{Maybe{T, F}}, m::Maybe{T, F}) where {T, F} = m   # resolves the method above against Base's `convert(::Type{T}, ::T)`

# Declared values are stored with the field types the run will carry: a `Union{Nothing,T}`
# becomes a `Maybe` (a Julia `Union` field in the carried context costs copies every step).
_to_storage_type(::Type{T}) where {T} = (T isa Union && Nothing <: T && T !== Nothing) ? make_maybe_type(Base.typesplit(T, Nothing)) : T
@generated _to_storage_types(::Type{NT}) where {NT<:NamedTuple} =
    :(NamedTuple{$(fieldnames(NT)), Tuple{$(map(_to_storage_type, fieldtypes(NT))...)}})
@inline _convert_to_storage(values::NT) where {NT<:NamedTuple} =
    _to_storage_types(NT)(map((T, v) -> convert(T, v), fieldtypes(_to_storage_types(NT)), Tuple(values)))

############################################################################################
# 3. Reading and writing during a run
############################################################################################

#=
A local without a value holds a placeholder until its first write, which replaces it, so the runtime context changes
type, once:
- declared without a type (`local x`, placeholder `undef`; or a `nothing` starting value): the field gets the type of
  the value written (for a `nothing` local, a `Maybe` of it, which reads as `nothing` when `nothing` is written again);
- declared with type `T` (`local x::T`, placeholder `UndefLocal{T}`): the value is converted to `T`, stored as
  `_to_storage_type(T)` (a `Union{Nothing,T}` as a `Maybe`). The conversion is compiled away when the value already
  has the type. The loop continues
with the new type (`_repeat_steps`, `_run_steps`, Loops.jl), and a block on a schedule gives the local the written type when it ran
and the placeholder when it did not (`_compute_conditional_loopcontext_type`, Step.jl). Later writes are converted to
that type, as for a local declared with one.
=#

"""Whether a local's field type `T` is a placeholder, which its first write replaces."""
_is_placeholder_local(::Type{T}) where {T} = T === UndefInitializer || T === Nothing || T <: UndefLocal

"""Build the expression for what a placeholder local (field type `P`) holds after its first write of `value` (an expression) of type `V`."""
_build_first_write_expr(::Type{UndefInitializer}, ::Type{V}, value) where {V} = value
_build_first_write_expr(::Type{Nothing}, ::Type{V}, value) where {V} = V === Nothing ? value : :($(make_maybe_type(V))($value))
_build_first_write_expr(::Type{UndefLocal{T}}, ::Type{V}, value) where {T, V} = :(convert($(_to_storage_type(T)), $value))

"""Write a step's returns `args` into the locals `old`: a placeholder is replaced by the value, anything else is converted to the local's type."""
@inline @generated function _write_locals(old::NT, args::A) where {NT<:NamedTuple, A<:NamedTuple}
    values = map(fieldnames(NT)) do name
        !(name in fieldnames(A)) && return :(getfield(old, $(QuoteNode(name))))
        _is_placeholder_local(fieldtype(NT, name)) && return _build_first_write_expr(fieldtype(NT, name), fieldtype(A, name), :(getfield(args, $(QuoteNode(name)))))
        return :(convert($(fieldtype(NT, name)), getfield(args, $(QuoteNode(name)))))
    end
    return :(NamedTuple{$(fieldnames(NT))}(($(values...),)))
end

include("HookExtensions.jl")
