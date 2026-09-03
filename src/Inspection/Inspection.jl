export inspect, InspectionReport

"""
    inspect(la::LoopSpec; globals = (;), inputs = (;), steps = true)

Build a displayable structural report for a loop algorithm.

`inspect` is a structural diagnostic for understanding composition boundaries.
It resolves the loop algorithm, lists the registry entries, routes, shares, and
stateful contexts, then runs the best-effort `ContextAnalyser` init/step passes.
It does not initialize a real `ProcessContext` or run the hot loop. The analyzer
does call user `init` and `step!` methods with recording views, so hooks that
mutate captured objects or perform external side effects can still do so.

Runtime-input metadata is reported when DSL `@input` declarations are attached
to the loop algorithm.
"""
function inspect(la::LA; globals = (;), inputs = (;), steps::Bool = true) where {LA<:LoopSpec}
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

struct InspectionRoute{Mappings,Transform,ReverseTransform}
    target::Symbol
    source::Symbol
    mappings::Mappings
    transform::Transform
    reverse_transform::ReverseTransform
end

struct InspectionRuntimeInput{Default}
    name::Symbol
    type_label::String
    required::Bool
    default::Default
    has_default::Bool
end

struct InspectionExecutionNode
    label::String
    children::Vector{InspectionExecutionNode}
end

struct InspectionReport{Original,Resolved,Routes,RuntimeInputEntries,InitMemory,StepMemory}
    original::Original
    resolved::Resolved
    resolve_error::Union{Nothing, String}
    registry_entries::Vector{InspectionEntry}
    state_entries::Vector{InspectionEntry}
    algorithm_entries::Vector{InspectionEntry}
    shares::Vector{InspectionShare}
    routes::Routes
    runtime_inputs::RuntimeInputEntries
    execution_plan::InspectionExecutionNode
    init_memory::InitMemory
    step_memory::StepMemory
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
            mappings = Pair{Symbol,Symbol}[varnames[i] => aliases[i] for i in eachindex(varnames)]
            push!(routes, InspectionRoute(target, source, mappings, gettransform(shared), getreverse_transform(shared)))
        end
    end

    return shares, routes
end

_inspection_tuple(value::Tuple) = value
_inspection_tuple(value) = (value,)

"""Collect display metadata for the runtime inputs declared by a loop algorithm."""
function _inspection_runtime_inputs(la::LA) where {LA<:AbstractLoopAlgorithm}
    return _inspection_runtime_inputs(runtimeinputs(la))
end

"""Convert a `RuntimeInputs` bundle into inspection-report entries."""
function _inspection_runtime_inputs(inputs::RI) where {RI<:RuntimeInputs}
    return InspectionRuntimeInput[
        InspectionRuntimeInput(
            _runtime_input_name(spec),
            sprint(show, _runtime_input_type(spec)),
            _runtime_input_required(spec),
            getfield(spec, :default),
            !_runtime_input_required(spec),
        )
        for spec in getfield(inputs, :specs)
    ]
end

"""Build an execution tree from the resolved wrapper's concrete plan."""
function _inspection_execution_plan(la::LA) where {LA<:AbstractLoopAlgorithm}
    return InspectionExecutionNode(_inspection_loop_label(la), _inspection_execution_children(getplan(la)))
end

"""Build display nodes for children scheduled by composite-style intervals."""
function _inspection_execution_children(la::LA) where {LA<:CompositeAlgorithm}
    funcs = getalgos(la)
    schedule = intervals(la)
    return InspectionExecutionNode[
        _inspection_execution_node(
            funcs[i],
            _inspection_schedule_label(:every, schedule[i]),
            plan_child_namespace(la, i),
        )
        for i in eachindex(funcs)
    ]
end

"""Build display nodes for children scheduled by routine lifetimes."""
function _inspection_execution_children(la::LA) where {LA<:Routine}
    funcs = getalgos(la)
    schedule = lifetimes(la)
    return InspectionExecutionNode[
        _inspection_execution_node(
            funcs[i],
            _inspection_routine_schedule_label(schedule[i]),
            plan_child_namespace(la, i),
        )
        for i in eachindex(funcs)
    ]
end

"""Delegate child-tree display from a runtime wrapper to its stored plan."""
function _inspection_execution_children(la::LA) where {LA<:AbstractLoopAlgorithm}
    return _inspection_execution_children(getplan(la))
end

"""Display children of an extensible plan type not handled by a specific method."""
function _inspection_execution_children(la::LA) where {LA<:AbstractPlan}
    funcs = getalgos(la)
    if iscomposite(la)
        schedule = intervals(la)
        return InspectionExecutionNode[
            _inspection_execution_node(
                funcs[i],
                _inspection_schedule_label(:every, schedule[i]),
                plan_child_namespace(la, i),
            )
            for i in eachindex(funcs)
        ]
    end
    return InspectionExecutionNode[
        _inspection_execution_node(funcs[i], "step", plan_child_namespace(la, i))
        for i in eachindex(funcs)
    ]
end

"""Build one scheduled execution-tree node, recursing into nested plans."""
function _inspection_execution_node(obj::O, schedule::S, key::K) where {O,S<:AbstractString,K<:Union{Nothing,Symbol}}
    if obj isa AbstractIdentifiableAlgo && getalgo(obj) isa LoopSpec
        inner = getalgo(obj)
        return InspectionExecutionNode(
            string(_inspection_execution_entry_label(obj, key), " (", schedule, ")"),
            _inspection_execution_children(inner),
        )
    elseif obj isa LoopSpec
        label = isnothing(key) ? _inspection_loop_label(obj) : string(key, ": ", _inspection_loop_label(obj))
        return InspectionExecutionNode(
            string(label, " (", schedule, ")"),
            _inspection_execution_children(obj),
        )
    else
        return InspectionExecutionNode(
            string(_inspection_execution_entry_label(obj, key), " (", schedule, ")"),
            InspectionExecutionNode[],
        )
    end
end

"""Label an execution leaf with its resolved child key when one is available."""
function _inspection_execution_entry_label(obj::O, key::K) where {O,K<:Union{Nothing,Symbol}}
    return isnothing(key) ? _inspection_entry_label(obj) : string(key, ": ", _inspection_label(obj))
end

function _inspection_entry_label(obj)
    key = _inspection_key(obj)
    if isnothing(key)
        return _inspection_label(obj)
    end
    return string(key, ": ", _inspection_label(obj))
end

"""Return a concise kind label for a loop plan or runtime wrapper."""
function _inspection_loop_label(la::LA) where {LA<:CompositeAlgorithm}
    return "CompositeAlgorithm"
end

function _inspection_loop_label(la::LA) where {LA<:Routine}
    return "Routine"
end

function _inspection_loop_label(la::LA) where {LA<:AbstractLoopAlgorithm}
    return sprint(summary, la)
end

function _inspection_loop_label(la::LA) where {LA<:AbstractPlan}
    return string(nameof(LA))
end

"""Format a routine child lifetime without displaying its condition closure."""
function _inspection_routine_schedule_label(spec::LT) where {LT<:Lifetime}
    if spec isa Repeat
        return string("Repeat(", repeats(spec), ")")
    elseif spec isa Indefinite
        return "Indefinite()"
    elseif spec isa Until
        return "Until(condition)"
    elseif spec isa AtLeast
        return string("AtLeast(", getfield(spec, :atleast), ", condition)")
    elseif spec isa RepeatOrUntil
        return string("RepeatOrUntil(", repeats(spec), ", condition)")
    elseif spec isa AtLeastAtMost
        return string(
            "AtLeastAtMost(",
            getfield(spec, :atleast),
            ", ",
            repeats(spec),
            ", condition)",
        )
    end
    return string(nameof(LT))
end

function _inspection_schedule_label(kind::Symbol, interval::I) where {I<:Interval}
    return string(kind, " ", getinterval(interval))
end

function _inspection_schedule_label(kind::Symbol, value)
    return string(kind, " ", value)
end

include("Showing.jl")
