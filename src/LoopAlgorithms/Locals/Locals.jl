export Local, Declaration

#=
AI GENERATED
Declared locals: variables a plan declares for its children to share, like `local x` before a
Julia loop. A declaration lives on the plan that makes it (in its `PlanWiring`); the values live
in the runtime context's `_declared_locals` subcontext, one slot per declaration.

1. Declaring     `Local`, the placeholders of locals without a value (`undef`, `UndefLocal{T}`), how declarations are
                 collected and named
2. Reading and writing during a run: a local's field has the type Julia would give the variable
3. Typing the locals before the loop

How the placeholders read and show (their hook methods) is in HookExtensions.jl.
=#

############################################################################################
# 1. Declaring
############################################################################################

"""
    Local(:x, :y => Float64, ...)

Declare loop-local variables on a plan without a value, like `local x` (and `local y::Float64`) before a Julia `for`
loop; what a DSL block's `local x` becomes. Pass it to `CompositeAlgorithm(...)` or `Routine(...)` like a route. A
name alone gets the type Julia would give the variable, the union of what the steps write to it (section 2); `name => T`
has type `T`.
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
starts, and the type of `value` joined with what the steps write to it (section 2; `x = nothing`, then `Float64`s, is a
`Union{Nothing,Float64}`, as a Julia variable). For plans built with constructors; a DSL block declares locals without a value
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
Placeholder of a local declared with type `T` and without a value (`local x::T`, `Local(:x => T)`): reading it throws
`UndefRefError`; writes are converted to `T` (section 2). A local declared without a type has the placeholder `undef`
instead.
"""
struct UndefLocal{T} end

"""The field type a declared local starts with, for its declared value of type `T`: `Union{UndefLocal{T}, T}` for a typed local without a value, else `T` (the steps' writes are joined to it, section 2)."""
_initial_local_type(::Type{T}) where {T} = T
_initial_local_type(::Type{UndefLocal{T}}) where {T} = Union{UndefLocal{T}, T}

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
            push!(types, _initial_local_type(fieldtype(Declared, name)))   # a declared `Union{Nothing,T}` stays one
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
# 2. Reading and writing during a run
############################################################################################

#=
A declared local's field has the type Julia would give the variable: the union of the type of its starting value or
placeholder and of every type the steps write to it. It is found before the loop by inferring a step of the plan and
joining what it writes, until that no longer changes (`settle_locals`, section 3), as Julia's inference does for a
variable assigned in a loop. So the runtime context has the same type in every step, and a write stores its value.
- `local x`: placeholder `undef`, so the field is `Union{UndefInitializer, ...}`; reading it before the first write throws.
  Julia keeps "not assigned yet" as a flag next to the variable; here the placeholder is a member of the field's
  `Union`, and the union's tag is that flag.
- `local x::T`: placeholder `UndefLocal{T}`, field `Union{UndefLocal{T}, T}`; a write is converted to `T`.
- a starting value (`Declaration(x = nothing)`): its type is part of the union, as `c = nothing` before a Julia loop.
A write of a type the field does not hold (one inference did not see) widens the field to the union, so the runtime
context changes type; the loop then continues with the new type (`_repeat_steps`, `_run_steps`, Loops.jl).
=#

"""The declared type `T` of a typed local with field type `F` (`UndefLocal{T}` is a member of `F`), or `nothing` for an untyped one."""
function _declared_local_type(@nospecialize(F))
    for M in Base.uniontypes(F)
        M <: UndefLocal && return M.parameters[1]
    end
    return nothing
end

"""The field type of a local after a write of type `V` into its field type `F`: `F` when it holds `V`, else their union (as Julia joins the types assigned to a variable)."""
_type_after_write(@nospecialize(F), @nospecialize(V)) = V <: F ? F : Union{F, V}

"""
Write a step's returns `args` into the locals `old` and return the new locals: each written value is stored (converted to
the declared type of a typed local), and a field's type is `_type_after_write` of it, the same as before when the
locals are settled (section 3).
"""
@inline @generated function _write_locals(old::NT, args::A) where {NT<:NamedTuple, A<:NamedTuple}
    names = fieldnames(NT)
    types = Any[]
    values = Any[]
    for name in names
        F = fieldtype(NT, name)
        if !(name in fieldnames(A))
            push!(types, F); push!(values, :(getfield(old, $(QuoteNode(name)))))
            continue
        end
        T = _declared_local_type(F)
        value = :(getfield(args, $(QuoteNode(name))))
        push!(types, _type_after_write(F, T === nothing ? fieldtype(A, name) : T))
        push!(values, T === nothing ? value : :(convert($T, $value)))
    end
    New = NamedTuple{names, Tuple{types...}}
    return :($New(($(values...),))::$New)
end

############################################################################################
# 3. Typing the locals before the loop
############################################################################################

const SETTLE_ROUNDS = 6

"""
    settle_locals(runtime_context, plan, cursor, persistent_context, wiring, process, lifetime)

`runtime_context` with each declared local's field typed as Julia would type the variable (section 2): one step of
`plan` is inferred with the current locals type, what it writes is joined to it, and that is repeated until it no
longer changes (at most `SETTLE_ROUNDS` rounds; locals still changing after that widen at run time, section 2). It
runs while the loop is compiled: every round is a `Core.Compiler.return_type` that inference folds.
"""
@inline function settle_locals(runtime_context::RC, plan::PL, cursor::CU, persistent_context::PC, wiring::W, process::P, lifetime::LT) where {RC<:ProcessContext, PL, CU, PC<:ProcessContext, W, P, LT}
    _has_declared_locals(RC) || return runtime_context
    R1 = @inline _settle_round(RC, plan, cursor, persistent_context, wiring, process, lifetime)
    R2 = @inline _settle_round(R1, plan, cursor, persistent_context, wiring, process, lifetime)
    R3 = @inline _settle_round(R2, plan, cursor, persistent_context, wiring, process, lifetime)
    R4 = @inline _settle_round(R3, plan, cursor, persistent_context, wiring, process, lifetime)
    R5 = @inline _settle_round(R4, plan, cursor, persistent_context, wiring, process, lifetime)
    R6 = @inline _settle_round(R5, plan, cursor, persistent_context, wiring, process, lifetime)
    return @inline _retype_locals(runtime_context, R6)
end

"""Whether runtime context type `RC` has declared locals."""
Base.@assume_effects :foldable _has_declared_locals(@nospecialize(RC)) = :_declared_locals in fieldnames(fieldtype(RC, :subcontexts))

"""One round of `settle_locals`: the runtime context type `RC` with the locals joined to what one inferred step of `plan` writes to them."""
@inline function _settle_round(::Type{RC}, plan::PL, cursor::CU, persistent_context::PC, wiring::W, process::P, lifetime::LT) where {RC, PL, CU, PC, W, P, LT}
    stepped = Core.Compiler.return_type(_step!, Tuple{PL, CU, _loop_context_type(PC, RC, W), W, Namespace{nothing}, P, LT})
    return _join_stepped_locals(RC, _runtime_context_types_of(stepped))
end

"""
`RC` with each declared local's field type joined with its types in the runtime context types `stepped` (a `Union` of
them; `Union{}` when the step always throws, `Any` when inference could not tell: then `RC` is kept).
"""
Base.@assume_effects :foldable function _join_stepped_locals(@nospecialize(RC), @nospecialize(stepped))
    (stepped === Union{} || stepped === Any) && return RC
    D = fieldtype(RC, :subcontexts)
    Locals = getdatatype(fieldtype(D, :_declared_locals))
    joined = Any[fieldtype(Locals, name) for name in fieldnames(Locals)]
    for S in Base.uniontypes(stepped)
        StepLocals = getdatatype(fieldtype(fieldtype(S, :subcontexts), :_declared_locals))
        for (i, name) in enumerate(fieldnames(Locals))
            joined[i] = _type_after_write(joined[i], fieldtype(StepLocals, name))
        end
    end
    NewLocals = NamedTuple{fieldnames(Locals), Tuple{joined...}}
    parts = Any[name === :_declared_locals ? SubContext{:_declared_locals, NewLocals} : fieldtype(D, name) for name in fieldnames(D)]
    return ProcessContext{NamedTuple{fieldnames(D), Tuple{parts...}}, fieldtype(RC, :reg)}
end

"""`runtime_context` with its declared locals stored with the field types of runtime context type `RC`."""
@inline @generated function _retype_locals(runtime_context::RuntimeContextType, ::Type{RC}) where {RuntimeContextType<:ProcessContext, RC}
    RuntimeContextType === RC && return :runtime_context
    Locals = getdatatype(fieldtype(fieldtype(RC, :subcontexts), :_declared_locals))
    return :(@inline with_subcontext(runtime_context, Val(:_declared_locals),
                 SubContext{:_declared_locals}($Locals(Tuple(get_declared_locals(runtime_context))))))
end

include("HookExtensions.jl")
