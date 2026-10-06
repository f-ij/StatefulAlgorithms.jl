export Local

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
    Local(; name = initial_value, ...)

Declare loop-local variables on a plan, like `local x = 0` before a Julia `for` loop. Pass it
to `CompositeAlgorithm(...)` or `Routine(...)` like a route.

- Scope: the declaring plan and everything below it; the nearest declaration of a name wins,
  and each copy of a plan has its own slot.
- Lifetime: one run. Created when the run starts, kept across pause/resume, not saved.
- Use: children read a local by name and update it by returning that name.
- Type: the initial value's type; returned values are converted to it. A local declared
  without a value (`undef` here, `local x` in the DSL) or as `nothing` gets its type from the
  values written to it, worked out before the run (section 4).

Sharing a value between children or across steps means declaring it here; undeclared step
returns are not meant to outlive the step that produced them.
"""
struct Local{NT<:NamedTuple} <: AbstractOption
    values::NT
    Local{NT}(values::NT) where {NT<:NamedTuple} = new{NT}(values)
end

Local(; values...) = Local(NamedTuple(values))

# Declared values are stored with the field types the run will carry: a `Union{Nothing,T}`
# becomes a `Maybe` (a Julia `Union` field in the carried context costs copies every step).
Local(values::NT) where {NT<:NamedTuple} = Local{_local_storage_type(NT)}(_local_storage(values))

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
Name of a local's slot in the runtime `_declared_locals` subcontext. A local declared on the root
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
memory for all of them is allocated in `_declared_locals` when a run starts.
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
_maybe_flagtype(::Type{T}) where {T} = (a = Base.datatype_alignment(T); a >= 8 ? UInt64 : a == 4 ? UInt32 : a == 2 ? UInt16 : UInt8)
Base.convert(::Type{Maybe{T, F, Empty}}, ::Empty) where {T, F, Empty} = Maybe{T, F, Empty}()
Base.convert(::Type{Maybe{T, F, Empty}}, x) where {T, F, Empty} = Maybe{T, F, Empty}(convert(T, x))
Base.convert(::Type{M}, m::M) where {M<:Maybe} = m

############################################################################################
# 3. Reading and writing during a run
############################################################################################

"""
The target of the routes that bind a view's visible locals: the view itself, since a local
binding has no target algorithm (see `routes(::PlanWiringView)`).
"""
struct LocalScope <: AbstractScope end

# Reads: a `Maybe` reads as its value, or as `nothing` / an error while unset.
_throw_undef() = throw(UndefRefError())
@inline subcontext_view_value(m::Maybe{T, F, Nothing}, view::V) where {T, F, V<:SubContextView} =
    !iszero(getfield(m, :isset)) ? subcontext_view_value(getfield(m, :value), view) : nothing
@inline subcontext_view_value(m::Maybe{T, F, UndefInitializer}, view::V) where {T, F, V<:SubContextView} =
    !iszero(getfield(m, :isset)) ? subcontext_view_value(getfield(m, :value), view) : _throw_undef()
# A local declared without a value that no step ever writes keeps its `undef`.
@inline subcontext_view_value(::UndefInitializer, view::V) where {V<:SubContextView} = _throw_undef()

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
(`_settle_locals`), so the context has its final type from the start: a local without a value
becomes `Maybe{T,F,UndefInitializer}`, a `nothing` local `Maybe{T,F,Nothing}`. Values written with
different types are promoted to one type.

Everything here works on types, not values: a "probe" is a field *type* that stands in for such
a local while inference finds out what gets written to it.
=#

"""Inference-only stand-in for an untyped local while its type is worked out; never constructed."""
struct LocalProbe{T, Empty, Written} end   # T: the local's type so far; Written: the types actually written (for error messages)
@inline subcontext_view_value(::LocalProbe{T, UndefInitializer}, view::V) where {T, V<:SubContextView} =
    T === Union{} ? _throw_undef() : _probe_value(T)
@inline subcontext_view_value(::LocalProbe{T, Nothing}, view::V) where {T, V<:SubContextView} = _probe_value(Union{Nothing, T})
_probe_value(::Type{T}) where {T} = Base.inferencebarrier(nothing)::T

"""Inference only: a write to a probe records the written type and keeps the field a probe."""
@generated _probe_write(::LocalProbe{T, Empty, Written}, ::V) where {T, Empty, Written, V} =
    :($(LocalProbe{_join_written(T, V, Empty), Empty, Union{Written, Empty === Nothing ? Base.typesplit(V, Nothing) : V}}()))
function _join_written(T, V, Empty)
    Empty === Nothing && (V = Base.typesplit(V, Nothing))   # writing `nothing` to a `nothing` local is always allowed
    V === Union{} && return T
    return T === Union{} ? V : promote_type(T, V)
end

_is_untyped_local(::Type{T}) where {T} = T === UndefInitializer || T === Nothing

"""Runtime context type with every untyped local replaced by a probe that has seen no writes."""
@generated function _probe_runtime_type(::Type{RC}) where {RC<:ProcessContext}
    return _replace_local_types(RC) do name, T
        _is_untyped_local(T) ? LocalProbe{Union{}, T, Union{}} : T
    end
end

"""
The probes in context type `RC`, each widened by the types the step wrote to it. `RT` is what
inference says one plan step returns: `Tuple{context, runtimecontext}`, or a union of those.
"""
@generated function _next_probe_type(::Type{RC}, ::Type{RT}) where {RC<:ProcessContext, RT}
    _inferred_contexts(RT) === nothing && return :(Nothing)   # not inferable: `_settle_locals` names the step
    returned = _inferred_contexts(RT)
    return _replace_local_types(RC) do name, P
        P <: LocalProbe || return P
        T, Empty = P.parameters
        for R in returned
            W = fieldtype(_local_data_type(R), name)
            T = _join_written(T, W <: LocalProbe ? W.parameters[1] : W, Empty)
        end
        return LocalProbe{T, Empty, Union{}}
    end
end

"""The runtime context types a step can return (`RT` is `Tuple{context, runtimecontext}` or a union of those), or `nothing` if inference could not tell."""
function _inferred_contexts(RT)
    tuples = RT === Union{} ? () : Base.uniontypes(RT)
    all(T -> T <: Tuple && fieldcount(T) == 2, tuples) || return nothing
    returned = unique(Iterators.flatten(Base.uniontypes(fieldtype(T, 2)) for T in tuples))
    all(C -> C isa DataType && C <: ProcessContext, returned) || return nothing
    return returned
end

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

@inline _probe_step(plan, cursor, context, runtimecontext, wiring, process, lifetime) =
    _step!(plan, cursor, context, runtimecontext, wiring, Namespace{nothing}(), process, lifetime)

"""
    _settle_locals(plan, cursor, context, runtimecontext, wiring, process, lifetime)

Give every local declared without a value or as `nothing` its final type, before the first
step. All of this is resolved while the run is compiled; nothing of it runs per step.

1. In the runtime context's type, each such local becomes a probe that has seen no writes.
2. Inference runs one plan step on that type. A write to a probe stores nothing; it records
   the written type in the probe. Inference covers every branch, so a write that only
   happens later or under a condition is included. Different types from different writers
   are promoted to one type. This is the local's type.
3. Check the design rule that a local keeps its type after the first value: run inference
   once more, now with each local read as its type. A step that reads a local and writes it
   back (`x = f(x)`) must write the same type; if any local changes, it is an error.
4. Each local is created as an unset `Maybe` of its type.
"""
@inline function _settle_locals(plan, cursor, context, runtimecontext::RC, wiring, process, lifetime) where {RC<:ProcessContext}
    _has_untyped_locals(RC) || return runtimecontext
    step = (plan, cursor, context, wiring, process, lifetime)
    no_writes_seen = _probe_runtime_type(RC)
    typed = _widen_probes(no_writes_seen, step...)   # each local's type
    typed === Nothing && _local_type_error(no_writes_seen, false, step...)
    checked = _widen_probes(typed, step...)          # the same, with each local read as that type
    checked === typed || _local_type_error(typed, true, step...)
    settled = _settled_locals(get_declared_locals(runtimecontext), typed)
    return @inline with_subcontext(runtimecontext, Val(:_declared_locals), SubContext{:_declared_locals}(settled))
end

"""
Throw the error for a failed local typing round, naming the steps (algorithms and calls) that
cause it: inference is repeated for each step on its own, with the locals as in `R`. While
`checking`, a step that writes a local with another type than its first is reported with both
types; in either round, a step whose return cannot be inferred is reported. Only runs to build
the error.
"""
function _local_type_error(::Type{R}, checking::Bool, plan, cursor, context, wiring, process, lifetime) where {R<:ProcessContext}
    culprits = String[]
    _find_local_type_culprits!(culprits, R, checking, plan, cursor, context, wiring, process, lifetime)
    isempty(culprits) && push!(culprits, checking ?
        "A local declared without a value (or as `nothing`) changes type after its first value, but no single step could be pinned down. For now this is not allowed: such a local takes the type of its first value and has to keep it. Declare the locals with a type (for example `Local(x = 0.0)`)." :
        "The type of a local declared without a value (or as `nothing`) cannot be found: the plan's step cannot be inferred. Declare the locals with a type (for example `Local(x = 0.0)`).")
    error(join(culprits, "\n\n"))
end

function _find_local_type_culprits!(culprits, ::Type{R}, checking, plan::AbstractPlan, cursor, context, wiring, process, lifetime) where {R}
    for i in 1:length(getalgos(plan))
        child = getalgo(plan, i)
        child_cursor = child_loop_cursor(cursor, Val(i))
        child_wiring = child_wiring_view(wiring, Val(i))
        if child isa AbstractPlan
            _find_local_type_culprits!(culprits, R, checking, child, child_cursor, context, child_wiring, process, lifetime)
            continue
        end
        namespace = getfield(getfield(plan, :namespaces), i)
        # What the step itself returns (before it is merged into the context), with the locals as in `R`.
        returned = Core.Compiler.return_type(_step_return, Tuple{typeof(child), typeof(context), R, typeof(child_wiring), typeof(namespace)})
        append!(culprits, _local_type_problems(_step_label(child, namespace), R, returned, typeof(child_wiring), checking))
    end
    return culprits
end

_step_label(child::Callable, ::Namespace) = _callable_string(child)
_step_label(child, namespace::Namespace) = string("`", namesymbol(namespace), "` (", nameof(typeof(child)), ")")

"""What a plan child's own step returns, as the plan's step would call it (calls are viewed from `_declared_outputs`)."""
@inline function _step_return(algo, context, runtimecontext, wiring, namespace::Namespace)
    viewed_as = algo isa Callable ? Namespace{:_declared_outputs}() : namespace
    contextview = view(context, runtimecontext, algo, viewed_as; sharedcontexts = shares(wiring), sharedvars = routes(wiring))
    return step!(algo, contextview)
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
        return [string(label, ": the type it emits cannot be inferred (it returns ", Returned, "), so the type of the locals it writes cannot be found either. Make the step return one type, or declare those locals with a type (for example `Local(x = 0.0)`).")]
    end
    checking || return String[]
    L = _local_data_type(R)
    problems = String[]
    for (name, slot) in pairs(W.parameters[4])        # the locals this step can see: name => slot
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
                " in that step, or give `", name, "` an initial ", first_type, " value in its `Local` declaration."))
        end
    end
    return unique(problems)
end

"""The probes in `R`, widened by every type one plan step (run with these probes) can write."""
@inline _widen_probes(::Type{R}, plan::PL, cursor::CU, context::C, wiring::W, process::P, lifetime::LT) where {R, PL, CU, C, W, P, LT} =
    _next_probe_type(R, Core.Compiler.return_type(_probe_step, Tuple{PL, CU, C, R, W, P, LT}))

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
