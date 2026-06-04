export inspect, InspectionReport

"""
    inspect(la::AbstractLoopAlgorithm; globals = (;), inputs = (;), steps = true)

Build a displayable structural report for a loop algorithm.

`inspect` is a read-only tool for understanding composition boundaries. It
resolves the loop algorithm, lists the registry entries, routes, shares, and
stateful contexts, then runs the best-effort `ContextAnalyser` init/step passes.
It does not initialize a real `ProcessContext`, mutate the input algorithm, or
run the hot loop.

Runtime-input metadata is intentionally reported only when it is declared on the
loop algorithm. The current implementation leaves that section empty because the
LoopAlgorithm-level `@input` feature is not built yet.
"""
function inspect(la::LA; globals = (;), inputs = (;), steps::Bool = true) where {LA<:AbstractLoopAlgorithm}
    resolved, resolve_error = _inspection_resolve(la)
    if isnothing(resolved)
        return InspectionReport(
            la,
            nothing,
            resolve_error,
            InspectionEntry[],
            InspectionEntry[],
            InspectionEntry[],
            InspectionShare[],
            InspectionRoute[],
            InspectionRuntimeInput[],
            InspectionExecutionNode("unresolved", InspectionExecutionNode[]),
            nothing,
            nothing,
        )
    end

    registry_entries = _inspection_registry_entries(resolved)
    state_entries = _inspection_filter_entries(registry_entries, :state)
    algo_entries = _inspection_filter_entries(registry_entries, :algorithm)
    shares, routes = _inspection_resolved_sharing(resolved)
    runtime_inputs = _inspection_runtime_inputs(resolved)
    execution_plan = _inspection_execution_plan(resolved)

    init_analysis = analyse_inits(resolved; globals, inputs)
    step_analysis = steps ? analyse_steps(resolved; globals, inputs) : nothing

    return InspectionReport(
        la,
        resolved,
        nothing,
        registry_entries,
        state_entries,
        algo_entries,
        shares,
        routes,
        runtime_inputs,
        execution_plan,
        _memory(init_analysis),
        isnothing(step_analysis) ? nothing : _memory(step_analysis),
    )
end

struct InspectionEntry
    key::Union{Nothing, Symbol}
    kind::Symbol
    label::String
    type_label::String
end

struct InspectionShare
    target::Symbol
    source::Symbol
end

struct InspectionRoute
    target::Symbol
    source::Symbol
    mappings::Vector{Pair}
    transform::Any
    reverse_transform::Any
end

struct InspectionRuntimeInput
    name::Symbol
    type_label::String
    required::Bool
    default::Any
    has_default::Bool
end

struct InspectionExecutionNode
    label::String
    children::Vector{InspectionExecutionNode}
end

struct InspectionReport
    original::Any
    resolved::Any
    resolve_error::Union{Nothing, String}
    registry_entries::Vector{InspectionEntry}
    state_entries::Vector{InspectionEntry}
    algorithm_entries::Vector{InspectionEntry}
    shares::Vector{InspectionShare}
    routes::Vector{InspectionRoute}
    runtime_inputs::Vector{InspectionRuntimeInput}
    execution_plan::InspectionExecutionNode
    init_memory::Any
    step_memory::Any
end

function _inspection_resolve(la)
    try
        return resolve(la), nothing
    catch err
        return nothing, sprint(showerror, err)
    end
end

function _inspection_kind(obj)
    inner = obj isa AbstractIdentifiableAlgo ? getalgo(obj) : obj
    if inner isa ProcessState
        return :state
    elseif inner isa ProcessAlgorithm
        return :algorithm
    elseif inner isa AbstractLoopAlgorithm
        return :loopalgorithm
    else
        return :object
    end
end

function _inspection_key(obj)
    try
        key = getkey(obj)
        return key isa Symbol ? key : nothing
    catch
        return nothing
    end
end

function _inspection_label(obj)
    try
        if obj isa IdentifiableAlgo
            return IdentifiableAlgo_label(obj)
        end
        return sprint(summary, obj)
    catch
        return string(typeof(obj))
    end
end

function _inspection_type_label(obj)
    inner = obj isa AbstractIdentifiableAlgo ? getalgo(obj) : obj
    return sprint(show, typeof(inner))
end

function _inspection_entry(obj)
    return InspectionEntry(
        _inspection_key(obj),
        _inspection_kind(obj),
        _inspection_label(obj),
        _inspection_type_label(obj),
    )
end

_inspection_entries(items) = [_inspection_entry(item) for item in items]

function _inspection_filter_entries(entries::Vector{InspectionEntry}, kind::Symbol)
    return InspectionEntry[entry for entry in entries if entry.kind == kind]
end

function _inspection_registry_entries(la::LA) where {LA<:AbstractLoopAlgorithm}
    reg = getregistry(la)
    isnothing(reg) && return InspectionEntry[]
    return _inspection_entries(all_algos(reg))
end

function _inspection_resolved_sharing(la::LA) where {LA<:AbstractLoopAlgorithm}
    sharedcontexts, sharedvars = _resolve_options(la)
    shares = InspectionShare[]
    routes = InspectionRoute[]

    for target in propertynames(sharedcontexts)
        for shared in _inspection_tuple(getproperty(sharedcontexts, target))
            source = contextname(shared)
            source isa Symbol && push!(shares, InspectionShare(target, source))
        end
    end

    for target in propertynames(sharedvars)
        for shared in _inspection_tuple(getproperty(sharedvars, target))
            source = get_fromname(shared)
            source isa Symbol || continue
            varnames = collect(subvarcontextnames(shared))
            aliases = collect(localnames(shared))
            mappings = Pair[varnames[i] => aliases[i] for i in eachindex(varnames)]
            push!(routes, InspectionRoute(target, source, mappings, gettransform(shared), getreverse_transform(shared)))
        end
    end

    return shares, routes
end

_inspection_tuple(value::Tuple) = value
_inspection_tuple(value) = (value,)

function _inspection_runtime_inputs(la::LA) where {LA<:AbstractLoopAlgorithm}
    if isdefined(@__MODULE__, :runtime_inputs)
        runtime_inputs_func = getfield(@__MODULE__, :runtime_inputs)
        if hasmethod(runtime_inputs_func, Tuple{typeof(la)})
            return _inspection_runtime_inputs(runtime_inputs_func(la))
        end
    end
    return InspectionRuntimeInput[]
end

function _inspection_runtime_inputs(inputs)
    return InspectionRuntimeInput[]
end

function _inspection_execution_plan(la::LA) where {LA<:AbstractLoopAlgorithm}
    return InspectionExecutionNode(_inspection_loop_label(la), _inspection_execution_children(la))
end

function _inspection_execution_children(la::CompositeAlgorithm)
    funcs = getalgos(la)
    schedule = intervals(la)
    return InspectionExecutionNode[
        _inspection_execution_node(funcs[i], _inspection_schedule_label(:every, schedule[i]))
        for i in eachindex(funcs)
    ]
end

function _inspection_execution_children(la::Routine)
    funcs = getalgos(la)
    schedule = repeats(la)
    return InspectionExecutionNode[
        _inspection_execution_node(funcs[i], _inspection_schedule_label(:repeat, schedule[i]))
        for i in eachindex(funcs)
    ]
end

function _inspection_execution_children(la::LA) where {LA<:AbstractLoopAlgorithm}
    funcs = getalgos(la)
    return InspectionExecutionNode[
        _inspection_execution_node(func, "step")
        for func in funcs
    ]
end

function _inspection_execution_node(obj, schedule::String)
    if obj isa AbstractIdentifiableAlgo && getalgo(obj) isa AbstractLoopAlgorithm
        inner = getalgo(obj)
        return InspectionExecutionNode(
            string(_inspection_entry_label(obj), " (", schedule, ")"),
            _inspection_execution_children(inner),
        )
    elseif obj isa AbstractLoopAlgorithm
        return InspectionExecutionNode(
            string(_inspection_loop_label(obj), " (", schedule, ")"),
            _inspection_execution_children(obj),
        )
    else
        return InspectionExecutionNode(string(_inspection_entry_label(obj), " (", schedule, ")"), InspectionExecutionNode[])
    end
end

function _inspection_entry_label(obj)
    key = _inspection_key(obj)
    if isnothing(key)
        return _inspection_label(obj)
    end
    return string(key, ": ", _inspection_label(obj))
end

function _inspection_loop_label(la::CompositeAlgorithm)
    return "CompositeAlgorithm"
end

function _inspection_loop_label(la::Routine)
    return "Routine"
end

function _inspection_loop_label(la::LA) where {LA<:AbstractLoopAlgorithm}
    return sprint(summary, la)
end

function _inspection_schedule_label(kind::Symbol, interval::Interval)
    return string(kind, " ", getinterval(interval))
end

function _inspection_schedule_label(kind::Symbol, value)
    return string(kind, " ", value)
end

include("Showing.jl")
