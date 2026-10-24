export Local, Declaration

#=
AI GENERATED
Declared locals: variables a plan declares for its children to share, like `local x` before a
Julia loop. A declaration lives on the plan that makes it (in its `PlanWiring`); the values live
in the runtime context's `_declared_locals` subcontext, one slot per declaration.

1. Declaring     `Local`, how declarations are collected and named
2. Storage       the placeholders of locals without a value (`undef`, `UndefLocal{T}`)
3. Reading and writing during a run: the first write replaces a placeholder with the type the writing step is
                 inferred to return, and a local declared with a type converts to it there

How the placeholders read and show (their hook methods) is in HookExtensions.jl.
=#

############################################################################################
# 1. Declaring
############################################################################################

"""
    Local(:x, :y => Float64, ...)

Declare loop-local variables on a plan without a value, like `local x` (and `local y::Float64`) before a Julia `for`
loop; what a DSL block's `local x` becomes. Pass it to `CompositeAlgorithm(...)` or `Routine(...)` like a route. A
name alone gets the type its first writer is inferred to return (section 3); `name => T` has type `T`.
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
starts, and the type of `value` (returned values are converted to it; `nothing` holds until the first write, and the
local then has the type the writing step is inferred to return). For plans built with constructors; a DSL block declares locals without a value
(`local x`) and keeps a starting value in `@state`.
"""
Declaration(; values...) = Declaration(NamedTuple(values))
Declaration(values::NamedTuple) = _build_local(values)

"""Build a `Local` from declared values, each stored with the type it has (a `Union{Nothing,T}` field as a `Union`)."""
_build_local(values::NT) where {NT<:NamedTuple} = Local{NT}(values)

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
    types = Any[]
    values = Any[]
    function collect!(@nospecialize(T::Type), @nospecialize(expr), @nospecialize(path))   # compiled once, not per plan node type or depth
        Declared = fieldtype(fieldtype(T, :wiring), :locals)
        for name in fieldnames(Declared)
            push!(names, make_storage_name(name, join(path, ".")))
            push!(types, fieldtype(Declared, name))   # the declared type: a `Union{Nothing,T}` stays one
            push!(values, :(getfield(getfield(getfield($expr, :wiring), :locals), $(QuoteNode(name)))))
        end
        F = fieldtype(T, :funcs)
        for i in 1:fieldcount(F)
            fieldtype(F, i) <: AbstractPlan && collect!(fieldtype(F, i), :(getfield(getfield($expr, :funcs), $i)), (path..., i))
        end
    end
    collect!(P, :plan, ())
    return :(NamedTuple{$(Tuple(names)), Tuple{$(types...)}}(($(values...),)))
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

############################################################################################
# 3. Reading and writing during a run
############################################################################################

#=
A local without a value holds a placeholder until its first write, which replaces it, so the runtime context changes
type, once:
- declared without a type (`local x`, placeholder `undef`; or a `nothing` starting value): the field gets the type the
  writing step is inferred to return for it (`_type_as_inferred`, ProcessAlgorithmStep.jl), not the type of the one
  value written: a step that returns `nothing` or a `Float64` gives `Union{Nothing,Float64}`, as Julia types a
  variable;
- declared with type `T` (`local x::T`, placeholder `UndefLocal{T}`): the field gets type `T` and the value is converted
  to it; a `Union{Nothing,T}` field holds `nothing` or a value. The conversion is compiled away when the value already
  has the type.
The loop continues with the new type (`_repeat_steps`, `_run_steps`, Loops.jl), and a block on a schedule gives the
local the written type when it ran and the placeholder when it did not (`_compute_conditional_loopcontext_type`,
Step.jl). Later writes are converted to that type, as for a local declared with one.
=#

"""Whether a local's field type `T` is a placeholder, which its first write replaces."""
_is_placeholder_local(::Type{T}) where {T} = T === UndefInitializer || T === Nothing || T <: UndefLocal

"""
The field type a local of field type `T` has after a write typed `V` (the inferred type of what the step returns for
it, see `_type_as_inferred`): a placeholder takes `V` (`undef`, `nothing`) or its declared type (`UndefLocal{T}`); any
other local keeps `T`.
"""
_type_after_write(::Type{T}, ::Type{V}) where {T, V} = T
_type_after_write(::Type{UndefInitializer}, ::Type{V}) where {V} = V
_type_after_write(::Type{Nothing}, ::Type{V}) where {V} = V
_type_after_write(::Type{UndefLocal{T}}, ::Type{V}) where {T, V} = T

"""
Write a step's returns `args` into the locals `old` and return the new locals, typed by `_type_after_write`: a
placeholder is replaced by the value, and every written value is converted to its field's type (compiled away when it
already has it).
"""
@inline @generated function _write_locals(old::NT, args::A) where {NT<:NamedTuple, A<:NamedTuple}
    names = fieldnames(NT)
    written(name) = name in fieldnames(A)
    types = map(name -> written(name) ? _type_after_write(fieldtype(NT, name), fieldtype(A, name)) : fieldtype(NT, name), names)
    values = map(name -> written(name) ? :(convert($(_type_after_write(fieldtype(NT, name), fieldtype(A, name))), getfield(args, $(QuoteNode(name))))) :
                                         :(getfield(old, $(QuoteNode(name)))), names)
    New = NamedTuple{names, Tuple{types...}}
    return :($New(($(values...),))::$New)
end

include("HookExtensions.jl")
