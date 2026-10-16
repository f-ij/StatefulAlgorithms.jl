export Local, Declaration

#=
AI GENERATED
Declared locals: variables a plan declares for its children to share, like `local x` before a
Julia loop. A declaration lives on the plan that makes it (in its `PlanWiring`); the values live
in the runtime context's `_declared_locals` subcontext, one slot per declaration.

1. Declaring     `Local`, how declared values are stored, how declarations are collected and named
2. Storage       `Maybe`, for locals that may not hold a value yet
3. Reading and writing during a run
4. Typing locals declared without a type (no value, or `nothing`), before the run
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

Local(names::Union{Symbol, Pair{Symbol, <:Type}}...) = _declared(NamedTuple(_unset_local(name) for name in names))
_unset_local(name::Symbol) = name => undef
_unset_local((name, T)::Pair{Symbol, <:Type}) = name => maybe_type(T, UndefInitializer)()
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
Declaration(values::NamedTuple) = _declared(values)

# Declared values are stored with the field types the run will carry: a `Union{Nothing,T}`
# becomes a `Maybe` (a Julia `Union` field in the carried context costs copies every step).
_declared(values::NT) where {NT<:NamedTuple} = Local{_local_storage_type(NT)}(_local_storage(values))

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
Name of the slot of a declared local (in `_declared_locals`) or a captured return (in `_captured_returns`). One of the
root plan keeps its name; one of a nested plan is suffixed with that plan's position, `x@1.2` (see `Scope`).
"""
# `path` is the plan's position, e.g. "1.2"; a `String` so the resolver's recursion keeps one type.
scoped_storage_name(name::Symbol, path::String) = isempty(path) ? name : Symbol(name, "@", path)

"""
Initial values of every local declared in a plan tree, keyed by storage name: the
memory for all of them is allocated in `_declared_locals` when a run starts.
"""
@generated function _tree_locals(plan::P) where {P<:AbstractPlan}
    names = Symbol[]
    values = Any[]
    function collect!(::Type{T}, expr, path) where {T}
        for name in fieldnames(fieldtype(fieldtype(T, :wiring), :locals))
            push!(names, scoped_storage_name(name, join(path, ".")))
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

############################################################################################
# 2. Storage
############################################################################################

"""
Flag-plus-value storage for a local that may not hold a value yet; `value` is undefined while
unset. `Empty` is what an unset local reads as: `Nothing` (reads give `nothing`) or
`UndefInitializer` (reads throw `UndefRefError`).

The flag is as wide as `T`'s alignment (`UInt64` for a `Float64`): a 1-byte `Bool` would leave
padding bytes in the struct, which the compiler copied on every step instead of keeping the
local in registers.
"""
struct Maybe{T, F<:Unsigned, Empty}
    isset::F      # as wide as T's alignment: a 1-byte Bool would leave padding that gets copied every step
    value::T
    Maybe{T, F, Empty}() where {T, F, Empty} = new{T, F, Empty}(zero(F))
    Maybe{T, F, Empty}(x) where {T, F, Empty} = new{T, F, Empty}(one(F), x)
end
maybe_type(::Type{T}, ::Type{Empty}) where {T, Empty} = Maybe{T, _maybe_flagtype(T), Empty}
_maybe_flagtype(::Type{T}) where {T} = isconcretetype(T) ? (a = Base.datatype_alignment(T); a >= 8 ? UInt64 : a == 4 ? UInt32 : a == 2 ? UInt16 : UInt8) : UInt8
Base.convert(::Type{Maybe{T, F, Empty}}, ::Empty) where {T, F, Empty} = Maybe{T, F, Empty}()
Base.convert(::Type{Maybe{T, F, Empty}}, x) where {T, F, Empty} = Maybe{T, F, Empty}(convert(T, x))
Base.convert(::Type{M}, m::M) where {M<:Maybe} = m

############################################################################################
# 3. Reading and writing during a run
############################################################################################

# Reads: a `Maybe` reads as its value, or as `nothing` / an error while unset.
_throw_undef() = throw(UndefRefError())
@inline view_value(view::V, m::Maybe{T, F, Nothing}) where {T, F, V<:SubContextView} =
    !iszero(getfield(m, :isset)) ? view_value(view, getfield(m, :value)) : nothing
@inline view_value(view::V, m::Maybe{T, F, UndefInitializer}) where {T, F, V<:SubContextView} =
    !iszero(getfield(m, :isset)) ? view_value(view, getfield(m, :value)) : _throw_undef()
"""A return as `final_context` shows it: a slot as its value, or `nothing` while unset."""
_final_value(x) = x
_final_value(m::Maybe) = iszero(getfield(m, :isset)) ? nothing : getfield(m, :value)
# A local declared without a value that no step ever writes keeps its `undef`.
@inline view_value(view::V, ::UndefInitializer) where {V<:SubContextView} = _throw_undef()

@inline @generated function _merge_declared(old::NT, args::A) where {NT<:NamedTuple, A<:NamedTuple}
    values = map(fieldnames(NT)) do name
        !(name in fieldnames(A)) && return :(getfield(old, $(QuoteNode(name))))
        fieldtype(NT, name) <: LocalProbe && return :(_probe_write(getfield(old, $(QuoteNode(name))), getfield(args, $(QuoteNode(name)))))
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
    T === Union{} ? _throw_undef() : _probe_value(T)
@inline view_value(view::V, ::LocalProbe{T, Nothing}) where {T, V<:SubContextView} = _probe_value(Union{Nothing, T})
_probe_value(::Type{T}) where {T} = Base.inferencebarrier(nothing)::T

"""
Inference only: a write to a probe joins the written type into the local's type and keeps the field a probe. A write
of a type the local already has leaves the probe's type as it is, so a step that may or may not write it (a child on
a schedule) gives one type, not two.
"""
@generated _probe_write(::LocalProbe{T, Empty}, ::V) where {T, Empty, V} =
    :($(LocalProbe{_join_written(T, V, Empty), Empty}()))
function _join_written(T, V, Empty)
    Empty === Nothing && (V = Base.typesplit(V, Nothing))   # writing `nothing` to a `nothing` local is always allowed
    V === Union{} && return T
    return T === Union{} ? V : promote_type(T, V)
end

_is_untyped_local(::Type{T}) where {T} = T === UndefInitializer || T === Nothing

_local_data_type(::Type{RC}) where {RC<:ProcessContext} = fieldtype(fieldtype(fieldtype(RC, :subcontexts), :_declared_locals), :data)

"""`RC` with each field type of its `_declared_locals` subcontext data replaced by `f(name, type)`."""
function _replace_local_types(f, ::Type{RC}) where {RC<:ProcessContext}
    D = fieldtype(RC, :subcontexts)
    :_declared_locals in fieldnames(D) || return RC
    L = _local_data_type(RC)
    newL = NamedTuple{fieldnames(L), Tuple{(f(n, fieldtype(L, n)) for n in fieldnames(L))...}}
    newD = NamedTuple{fieldnames(D), Tuple{(n === :_declared_locals ? SubContext{:_declared_locals, newL} : fieldtype(D, n) for n in fieldnames(D))...}}
    return ProcessContext{newD, fieldtype(RC, :reg)}
end

"""Runtime context type with every untyped local replaced by a probe that has seen no writes."""
@generated function _probe_runtime_type(::Type{RC}) where {RC<:ProcessContext}
    return _replace_local_types(RC) do name, T
        _is_untyped_local(T) ? LocalProbe{Union{}, T} : T
    end
end

"""
The probes in context type `RC`, each widened by the types the step wrote to it, given the runtime context types one
plan step can return (`returned`). Used by `_runtime_context_type_with_step_writes` (Outputs.jl).
"""
function _probe_joined_type(::Type{RC}, returned) where {RC<:ProcessContext}
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

"""The runtime context types a step can return (`RT` is a `LoopContext` type or a union of those), or `nothing` if inference could not tell."""
function _inferred_contexts(RT)
    loopcontexts = RT === Union{} ? () : Base.uniontypes(RT)
    all(T -> T isa DataType && T <: LoopContext, loopcontexts) || return nothing
    returned = unique(Iterators.flatten(Base.uniontypes(runtime_type(T)) for T in loopcontexts))
    all(C -> C isa DataType && C <: ProcessContext, returned) || return nothing
    return returned
end


@inline _probe_step(plan, cursor, lc, wiring, process, lifetime) =
    _step!(plan, cursor, lc, wiring, Namespace{nothing}(), process, lifetime)


"""
Throw the error for a failed local typing round, naming the steps (algorithms and calls) that
cause it: inference is repeated for each step on its own, with the locals as in `R`. While
`checking`, a step that writes a local with another type than its first is reported with both
types; in either round, a step whose return cannot be inferred is reported. Only runs to build
the error.
"""
function _local_type_error(::Type{R}, checking::Bool, plan, cursor, persistent_context, wiring, process, lifetime) where {R<:ProcessContext}
    culprits = String[]
    _find_local_type_culprits!(culprits, R, checking, plan, cursor, persistent_context, wiring, process, lifetime)
    isempty(culprits) && push!(culprits, checking ?
        "A local declared without a value (or as `nothing`) changes type after its first value, but no single step could be pinned down. For now this is not allowed: such a local takes the type of its first value and has to keep it. Declare the locals with a type (`local x::Float64`)." :
        "The type of a local declared without a value (or as `nothing`) cannot be found: the plan's step cannot be inferred. Declare the locals with a type (`local x::Float64`).")
    error(join(culprits, "\n\n"))
end

function _find_local_type_culprits!(culprits, ::Type{R}, checking, plan::AbstractPlan, cursor, persistent_context, wiring, process, lifetime) where {R}
    for i in 1:length(getalgos(plan))
        child = getalgo(plan, i)
        child_cursor = child_loop_cursor(cursor, Val(i))
        child_wiring = child_wiring_view(wiring, Val(i))
        if child isa AbstractPlan
            _find_local_type_culprits!(culprits, R, checking, child, child_cursor, persistent_context, child_wiring, process, lifetime)
            continue
        end
        namespace = getfield(getfield(plan, :namespaces), i)
        # What the step itself returns (before it is merged into the context), with the locals as in `R`.
        returned = Core.Compiler.return_type(_step_return, Tuple{typeof(child), LoopContext{typeof(persistent_context), R, wiring_parent(typeof(child_wiring))}, typeof(child_wiring), typeof(namespace)})
        append!(culprits, _local_type_problems(_step_label(child, namespace), R, returned, typeof(child_wiring), checking))
    end
    return culprits
end

_step_label(child::Callable, ::Namespace) = _callable_string(child)
_step_label(child, namespace::Namespace) = string("`", namesymbol(namespace), "` (", nameof(typeof(child)), ")")

"""What a plan child's own step writes back (see `step_updates`), as the plan's step would call it (calls are viewed from `_captured_returns`)."""
@inline function _step_return(algo, lc, wiring, namespace::Namespace)
    viewed_as = algo isa Callable ? Namespace{:_captured_returns}() : namespace
    contextview = view(lc, algo, viewed_as; sharedcontexts = shares(wiring), sharedvars = routes(wiring))
    return step_updates(step!(algo, contextview))
end

"""
The error paragraphs for one step (`label`): a step whose return cannot be inferred, or (while
`checking`) a step that takes a local as input and emits it with a type that does not fit the
local's first type. `returned` is the inferred type of what the step returns; `W` its wiring
view, whose visible locals map the names the step uses to the locals' `_declared_locals` slots.
"""
function _local_type_problems(label, ::Type{R}, ::Type{Returned}, ::Type{W}, checking::Bool) where {R, Returned, W}
    returns = Returned === Union{} ? () : Base.uniontypes(Returned)
    if !all(T -> T === Nothing || T <: NamedTuple, returns)
        return [string(label, ": the type it emits cannot be inferred (it returns ", Returned, "), so the type of the locals it writes cannot be found either. Make the step return one type, or declare those locals with a type (`local x::Float64` in a DSL block).")]
    end
    checking || return String[]
    L = _local_data_type(R)
    problems = String[]
    for (name, slot) in pairs(scope_locals(node_scope(wiring_parent(W))))        # the locals this step can see: name => slot
        P = fieldtype(L, slot)
        P <: LocalProbe || continue
        first_type, empty = P.parameters[1], P.parameters[2]
        for T in returns
            T <: NamedTuple && name in fieldnames(T) || continue
            written = fieldtype(T, name)
            # The emitted types that do not fit the first type (the rest converts to it).
            offending = filter(w -> _join_written(first_type, w, empty) !== first_type, Base.uniontypes(written))
            isempty(offending) && continue
            emitted = string(Union{offending...}) * (length(offending) == length(Base.uniontypes(written)) ? "" : " (it emits $written)")
            push!(problems, string(label, " takes the local `", name, "` as input with type ", first_type,
                " and emits it with a different type, ", emitted, ". For now this is not allowed for locals declared without a value (or as `nothing`): ",
                "they take the type of their first value and have to keep it. Emit `", name, "` as ", first_type,
                " in that step, or declare it with the type it should have (`local ", name, "::T`)."))
        end
    end
    return unique(problems)
end


@generated function _has_untyped_locals(::Type{RC}) where {RC<:ProcessContext}
    :_declared_locals in fieldnames(fieldtype(RC, :subcontexts)) || return false
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
