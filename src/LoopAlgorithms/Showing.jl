
@inline function _algo_label(f)
    if f isa IdentifiableAlgo
        return StatefulAlgorithms.IdentifiableAlgo_label(f)
    end
    return sprint(summary, f)
end

@inline function _tree_prefix(idx::Int, total::Int)
    branch = idx == total ? "└── " : "├── "
    stem = idx == total ? "    " : "│   "
    return branch, stem
end

function _print_tree_lines(io::IO, idx::Int, total::Int, lines::AbstractVector{<:AbstractString}; suffix::AbstractString = "")
    branch, stem = _tree_prefix(idx, total)
    print(io, branch, lines[1], suffix)
    for line in Iterators.drop(lines, 1)
        print(io, "\n", stem, line)
    end
end

"""A plan child as printed in its plan; a `Callable` shows its wires as argument sources."""
_plan_child_string(child, wiring, ctx) = repr(child; context = ctx)
_plan_child_string(child::Callable, wiring::Wiring, ctx) = _callable_string(child, wiring)

"""
The name a plan is shown with: `CompositeAlgorithm` when all its entries are intervals, `Routine` when all are
repeats, else `Plan`. `P` is the plan's type.
"""
function _plan_label(P::Type)
    entries = fieldtypes(fieldtype(P, 2))
    all(is_repeat_entry, entries) && !isempty(entries) && return "Routine"
    any(is_repeat_entry, entries) && return "Plan"
    return "CompositeAlgorithm"
end

"""How a child's schedule entry is shown after it: `(every n time(s))` for an interval, `(repeats n time(s))` for a repeat."""
_entry_suffix(entry::Union{Interval, RunIf}) = " (every " * string(entry) * " time(s))"
_entry_suffix(entry::Lifetime) = " (repeats " * string(repeats(entry)) * " time(s))"

function Base.show(io::IO, plan::Plan)
    println(io, _plan_label(typeof(plan)))
    funcs = getalgos(plan)
    if isempty(funcs)
        print(io, "└── (empty)")
        return
    end
    entries = getschedule(plan)
    limit = get(io, :limit, false)
    show_ctx = IOContext(io, :limit => limit, :color => get(io, :color, false))
    total = length(funcs)
    for (idx, thisfunc) in enumerate(funcs)
        func_str = _plan_child_string(thisfunc, getfield(child_wiring(getwiring(plan)), idx), show_ctx)
        lines = split(func_str, '\n')
        _print_tree_lines(io, idx, total, lines; suffix = _entry_suffix(entries[idx]))
        if idx < total
            print(io, "\n")
        end
    end
end

"""
Custom display helpers for composite algorithms.
"""

function _composite_algo_labels(funcs)
    labels = String[]
    for f in funcs
        if f isa IdentifiableAlgo
            push!(labels, StatefulAlgorithms.IdentifiableAlgo_label(f))
        else
            push!(labels, summary(f))
        end
    end
    return labels
end

function _composite_algo_type_labels(types::Tuple)
    labels = String[]
    for t in types
        if !(t isa Type)
            continue
        end
        if t <: IdentifiableAlgo
            algo_type = t.parameters[1]
            push!(labels, string(nameof(algo_type), "@", StatefulAlgorithms.getkey(t)))
        else
            push!(labels, string(nameof(t)))
        end
    end
    return labels
end

function _composite_algo_type_labels(types::Core.SimpleVector)
    return _composite_algo_type_labels(tuple(types...))
end

function Base.summary(io::IO, plan::Plan)
    label = _plan_label(typeof(plan))
    funcs = getalgos(plan)
    if isempty(funcs)
        print(io, label, " (empty)")
        return
    end
    entries = getschedule(plan)
    println(io, label)
    total = length(funcs)
    for (idx, f) in enumerate(funcs)
        lines = split(_algo_label(f), '\n')
        _print_tree_lines(io, idx, total, lines; suffix = _entry_suffix(entries[idx]))
        if idx < total
            print(io, "\n")
        end
    end
end

function Base.show(io::IO, planT::Type{<:Plan})
    dt = Base.unwrap_unionall(planT)
    if length(dt.parameters) == 0 || dt.parameters[1] isa TypeVar || dt.parameters[2] isa TypeVar
        print(io, "Plan")
        return
    end
    labels = _composite_algo_type_labels(dt.parameters[1].parameters)
    print(io, _plan_label(dt), "(", join(labels, ", "), ")")
end

"""
Display one runtime loop wrapper through its public execution plan.

`LoopAlgorithm` carries lifecycle data such as registry and persistent context, but
that data is internal noise for normal display. Showing the plan keeps process
trees focused on the algorithms the user asked to run.
"""
function Base.show(io::IO, la::LA) where {LA<:LoopAlgorithm}
    return show(io, getplan(la))
end

"""
Summarize one runtime loop wrapper with the summary of its execution plan.

This keeps one-line process summaries from expanding the concrete lifecycle
wrapper type, which can contain large context and registry parameters.
"""
function Base.summary(io::IO, la::LA) where {LA<:LoopAlgorithm}
    show(io, typeof(getplan(la)))
    return nothing
end

"""
Print a compact label for a `LoopAlgorithm` type: `LoopAlgorithm{plan type}`, eliding the lifecycle type parameters
that are not useful in user-facing output, or `LoopAlgorithm` when the plan type is not known (`LoopAlgorithm` itself,
or a type in a method signature whose plan is a type variable).
"""
function Base.show(io::IO, laT::Type{<:LoopAlgorithm})
    dt = Base.unwrap_unionall(laT)
    if length(dt.parameters) == 0
        print(io, "LoopAlgorithm")
        return nothing
    end

    plan = dt.parameters[1]
    if plan isa TypeVar
        print(io, "LoopAlgorithm")
    else
        print(io, "LoopAlgorithm{")
        show(io, plan)
        print(io, "}")
    end
    return nothing
end

"""
When a plan is wrapped by a scope
"""
function Base.show(io::IO, sa::IdentifiableAlgo{F, Id, Aliases, AlgoName, ScopeName}) where {F<:Plan, Id, Aliases, AlgoName, ScopeName}
    plan = getalgo(sa)
    header = isnothing(algoname(sa)) ? _plan_label(typeof(plan)) : string(algoname(sa))
    println(io, header, "@", getkey(sa))
    funcs = getalgos(plan)
    entries = getschedule(plan)
    total = length(funcs)
    for (idx, f) in enumerate(funcs)
        lines = split(_algo_label(f), '\n')
        _print_tree_lines(io, idx, total, lines; suffix = _entry_suffix(entries[idx]))
        if idx < total
            print(io, "\n")
        end
    end
end
