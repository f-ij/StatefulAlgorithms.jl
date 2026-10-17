#=
The errors thrown when locals declared without a type cannot be typed before the run (Locals.jl, section 4). They
name the steps (algorithms and calls) that cause it. Only runs to build the error.
=#

"""
Throw the error for a first typing round that could not infer the plan's step (locals as in `R`, all probes without
writes): names each step whose return cannot be inferred.
"""
_throw_uninferrable_step_error(::Type{R}, step...) where {R<:ProcessContext} = _throw_with_culprits(R, false,
    "The type of a local declared without a value (or as `nothing`) cannot be found: the plan's step cannot be inferred. Declare the locals with a type (`local x::Float64`).", step...)

"""
Throw the error for a local that changed type after its first value (locals as in `R`, the first round's types):
names each step that writes a local with another type than its first, with both types.
"""
_throw_local_type_change_error(::Type{R}, step...) where {R<:ProcessContext} = _throw_with_culprits(R, true,
    "A local declared without a value (or as `nothing`) changes type after its first value, but no single step could be pinned down. For now this is not allowed: such a local takes the type of its first value and has to keep it. Declare the locals with a type (`local x::Float64`).", step...)

"""
Throw an error naming the steps that cause it, found by inferring each step on its own with the locals as in `R`;
`fallback` when no single step is found. A step whose return cannot be inferred is always named; one that changes a
local's type only when `check_type_changes`.
"""
function _throw_with_culprits(::Type{R}, check_type_changes::Bool, fallback::String, plan, cursor, persistent_context, wiring, process, lifetime) where {R<:ProcessContext}
    culprits = String[]
    _find_local_type_culprits!(culprits, R, check_type_changes, plan, cursor, persistent_context, wiring, process, lifetime)
    isempty(culprits) && push!(culprits, fallback)
    error(join(culprits, "\n\n"))
end

function _find_local_type_culprits!(culprits, ::Type{R}, check_type_changes, plan::AbstractPlan, cursor, persistent_context, wiring, process, lifetime) where {R}
    for i in 1:length(getalgos(plan))
        child = getalgo(plan, i)
        child_cursor = child_loop_cursor(cursor, Val(i))
        child_wiring = child_wiring_view(wiring, Val(i))
        if child isa AbstractPlan
            _find_local_type_culprits!(culprits, R, check_type_changes, child, child_cursor, persistent_context, child_wiring, process, lifetime)
            continue
        end
        namespace = getfield(getfield(plan, :namespaces), i)
        # What the step itself returns (before it is merged into the context), with the locals as in `R`.
        returned = Core.Compiler.return_type(_infer_step_updates, Tuple{typeof(child), LoopContext{typeof(persistent_context), R, read_parent_wiring_type(typeof(child_wiring))}, typeof(child_wiring), typeof(namespace)})
        append!(culprits, _describe_local_type_problems(_describe_step(child, namespace), R, returned, typeof(child_wiring), check_type_changes))
    end
    return culprits
end

"""Describe a step for the error: a call as its source, an algorithm as its name and type."""
_describe_step(child::Callable, ::Namespace) = _callable_string(child)
_describe_step(child, namespace::Namespace) = string("`", namesymbol(namespace), "` (", nameof(typeof(child)), ")")

"""What a plan child's own step writes back (see `step_updates`), as the plan's step would call it (calls are viewed from `_captured_returns`). Only inferred, never run."""
@inline function _infer_step_updates(algo, lc, wiring, namespace::Namespace)
    viewed_as = algo isa Callable ? Namespace{:_captured_returns}() : namespace
    contextview = view(lc, algo, viewed_as; sharedcontexts = shares(wiring), sharedvars = routes(wiring))
    return step_updates(step!(algo, contextview))
end

"""
Describe the problems of one step (`label`) as error paragraphs: a step whose return cannot be inferred, or (when
`check_type_changes`) a step that takes a local as input and emits it with a type that does not fit the local's first type.
`returned` is the inferred type of what the step returns; `W` its wiring view, whose visible locals map the names the
step uses to the locals' `_declared_locals` slots.
"""
function _describe_local_type_problems(label, ::Type{R}, ::Type{Returned}, ::Type{W}, check_type_changes::Bool) where {R, Returned, W}
    returns = Returned === Union{} ? () : Base.uniontypes(Returned)
    if !all(T -> T === Nothing || T <: NamedTuple, returns)
        return [string(label, ": the type it emits cannot be inferred (it returns ", Returned, "), so the type of the locals it writes cannot be found either. Make the step return one type, or declare those locals with a type (`local x::Float64` in a DSL block).")]
    end
    check_type_changes || return String[]
    L = _get_locals_type(R)
    problems = String[]
    for (name, slot) in pairs(scope_locals(node_scope(read_parent_wiring_type(W))))        # the locals this step can see: name => slot
        P = fieldtype(L, slot)
        P <: LocalProbe || continue
        first_type, empty = P.parameters[1], P.parameters[2]
        for T in returns
            T <: NamedTuple && name in fieldnames(T) || continue
            written = fieldtype(T, name)
            # The emitted types that do not fit the first type (the rest converts to it).
            offending = filter(w -> _widen_local_type(first_type, w, empty) !== first_type, Base.uniontypes(written))
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
