"""Return `true` for a state that already carries its identity: an identifiable wrapper around a `AlgoState`."""
_is_identified_state(arg) = arg isa AbstractIdentifiableAlgo && getalgo(arg) isa AlgoState

"""Return `true` for loop-constructor children that run or describe runnable children."""
function _is_loop_child_input(arg)
    _is_identified_state(arg) && return false
    return arg isa Union{SteppableAlgorithm, AbstractPlan, Type{<:SteppableAlgorithm}, Type{<:AbstractPlan}, WithWiring}
end

"""
Return `true` when an argument belongs in the algorithm section of a loop constructor.

Named state pairs like `:_state => state` are intentionally excluded here so they
fall through to the later AlgoState parsing branch.
"""
function isa_processentity_input(arg)
    if arg isa ParserOption
        return true
    elseif _is_loop_child_input(arg)
        return true
    elseif arg isa Pair
        arg.first isa Symbol || construction_assert_error("If passing algorithms as pairs, the first element must be a Symbol representing the name of the algorithm, but got: ", arg.first)
        if arg.second isa ParserOption
            return true
        elseif _is_loop_child_input(arg.second)
            return true
        elseif arg.second isa AlgoState || arg.second isa Type{<:AlgoState}
            return false
        else
            construction_error("If passing algorithms as pairs, the second element must be a SteppableAlgorithm, AbstractPlan, matching Type, or ParserOption, but got: ", arg.second)
        end
    else
        return false
    end
end

@inline parse_parser_option(option::ParserOption) = error("parse_parser_option not implemented for $(typeof(option)).")
@inline parse_parser_option(option::IfWrapped) = option.cond ? option.algo : nothing

function _parse_loopalgorithm_entity_input(el)
    if el isa ParserOption
        return parse_parser_option(el)
    elseif el isa Pair && el.second isa ParserOption
        parsed = parse_parser_option(el.second)
        return isnothing(parsed) ? nothing : (el.first => parsed)
    end
    return el
end

Base.@nospecializeinfer function _normalize_loopalgorithm_entity_input(@nospecialize(el))
    # A child with a fixed namespace (a call) has no identity: not named, wrapped or registered.
    el isa Pair && !isnothing(fixed_namespace(el.second)) && return _normalize_loopalgorithm_entity_input(el.second)
    el isa WithWiring && return WithWiring(_normalize_loopalgorithm_entity_input(getfield(el, :child)), getfield(el, :wires))
    isnothing(fixed_namespace(el)) || return el
    if el isa Pair
        !(el.second isa LoopAlgorithmTypes) || construction_assert_error("Loop plans cannot currently be passed as pairs (aliased), but got: ", el.second, " in pair ", el)
        return IdentifiableAlgo(el.second, el.first)
    elseif el isa Union{ProcessEntity, Type{<:ProcessEntity}}
        return IdentifiableAlgo(el)
    else
        return el
    end
end

function _filter_loopalgorithm_specification(specification, kept_algos::Tuple)
    length(specification) == length(kept_algos) || construction_error("If passing intervals/repeats as a tuple, there must be one entry per algorithm input before parser options are filtered, but got ", specification, " for ", length(kept_algos), " algorithm inputs.")
    return tuple((specification[i] for i in eachindex(kept_algos) if kept_algos[i])...)
end

"""Return `true` when an argument belongs in the AlgoState section."""
@inline isa_algostate_input(arg) = _is_identified_state(arg) || (arg isa AlgoState) || (arg isa Type{<:AlgoState}) || (arg isa Pair && arg.first isa Symbol && (arg.second isa AlgoState || arg.second isa Type{<:AlgoState}))

#TODO: Don't allow Identifiable wrapping of LoopAlgorithms
"""
Call a LoopAlgorithm as:

LoopAlgorithm(  func1, func2, func3, ..., 
                tuple(interval1, interval2, interval3, ...),
                processstate1, processstate2, ..., 
                options1, option2, ...)

`kind` says what a plain number in the schedule tuple is (`_normalize_schedule_entry`): `Val(:interval)` for
`CompositeAlgorithm` and `ThreadedCompositeAlgorithm`, `Val(:repeat)` for `Routine`, which also needs the tuple and
gets `DefaultLifetime(Repeat(1))`.

Plain `Route` and `Share` options are stored on the top-level plan as global
routing metadata. DSL expansion can pass `LocalPlanOption` values when a
route/share belongs to a specific child plan node. Non-routing options stay on
the `LoopAlgorithm` runtime wrapper.
"""
function parse_la_input(laType::Type{LA}, kind::Val, args...) where {LA<:AbstractPlan}
    collected_options = tuple()

    ######### ALGORITHMS #########
    if args[1] isa Tuple
        @warn "Passing algorithms as a tuple will be deprecated, please pass intervals as a separate argument after all ProcessAlgorithms, e.g. LoopAlgorithm(func1, func2, (10, 20), option1, option2). Got: $(args[1])"
        args = (args[1]..., args[2:end]...)
    end

    processalgos = tuple()
    kept_algos = tuple()
    while true
        el, args = parse_by_func(isa_processentity_input, args...; error = false)
        if isnothing(el)
            break
        else
            parsed_el = _parse_loopalgorithm_entity_input(el)
            keep = !isnothing(parsed_el)
            kept_algos = tuple(kept_algos..., keep)
            if keep
                parsed_el = _strip_nested_finalized_algorithm(parsed_el)
                processalgos = tuple(processalgos..., _normalize_loopalgorithm_entity_input(parsed_el))
            end
        end
    end
    !isempty(processalgos) || construction_assert_error("At least one ProcessAlgorithm must be provided, but got: ", args)

    # Nested plans keep their local route/share metadata. Resolved wrappers may
    # still carry already-materialized options, so preserve those when composed.
    for algo in processalgos
        if algo isa LoopAlgorithm && isresolved(algo)
            collected_options = (unique(collected_options)..., update_option_keys(algo)...)
        end
    end
    ######### SCHEDULE #########
    # One entry per child: given as a tuple after the children, or (for interval kinds) every child every step.
    intervals_or_repeats = nothing
    if !isempty(args) && args[1] isa Tuple
        intervals_or_repeats = map(x -> _normalize_schedule_entry(kind, x), _filter_loopalgorithm_specification(args[1], kept_algos))
        args = args[2:end] # Remove the intervals from the arguments list for further processing
    elseif kind isa Val{:interval}
        intervals_or_repeats = ntuple(_ -> Interval(1), length(processalgos))
    end
    if isnothing(intervals_or_repeats)
        got = isempty(args) ? "no repeats" : repr(first(args))
        construction_error("For routines, please pass the number of repeats after all ProcessAlgorithms as a tuple, even if it's just one repeat, e.g. (10,). Got: ", got)
    end

    ### FLATTEN ###
    processalgos, intervals_or_repeats = flatten_comp_funcs(processalgos, tuple(intervals_or_repeats...))

    ######### STATES #########
    pstates = tuple()
    while true
        el, args = parse_by_func(isa_algostate_input, args...; error = false)
        if isnothing(el)
            break
        else
            if el isa Pair
                state = IdentifiableAlgo(el.second, el.first)
            elseif el isa Union{AlgoState, Type{<:AlgoState}}
                state = IdentifiableAlgo(el)
            else
                state = el
            end
            pstates = tuple(pstates..., state)
        end
    end

    options = tuple()
    if !isempty(args)
        options = tuple(args[1:end]...)
        all(x -> x isa Union{AbstractOption, AbstractWiring} || x isa Type{<:Union{AbstractOption, AbstractWiring}}, options) || construction_assert_error("All arguments after the AlgoStates must be options or wiring, but got: ", options)
    end
    options = tuple(collected_options..., options...)
    options = _with_default_lifetime(kind, options)
    return LoopAlgorithm(laType, processalgos, pstates, options, intervals_or_repeats)
end

"""
A schedule entry as given to a constructor of kind `kind`: an `Interval`, `RunIf` or `Lifetime` as it is, a number as
an `Interval` (`Val(:interval)`) or a `Repeat` (`Val(:repeat)`).
"""
_normalize_schedule_entry(::Val, entry::Union{Interval, RunIf, Lifetime}) = entry
_normalize_schedule_entry(::Val{:interval}, entry::Real) = Interval(entry)
_normalize_schedule_entry(::Val{:repeat}, entry::Real) = Repeat(entry)
_normalize_schedule_entry(::Val, entry) = construction_error("A schedule entry must be a number, an `Interval`, a `RunIf` or a lifetime (`Repeat(n)`, `Until(...)`, ...), but got: ", entry)

"""`options` with `DefaultLifetime(Repeat(1))` added for `Routine` (`Val(:repeat)`), unless one is there already."""
Base.@nospecializeinfer _with_default_lifetime(::Val, @nospecialize(options::Tuple)) = options
Base.@nospecializeinfer _with_default_lifetime(::Val{:repeat}, @nospecialize(options::Tuple)) =
    isnothing(find_default_lifetime(options)) ? (options..., DefaultLifetime(Repeat(1))) : options

"""
    LoopAlgorithm(PlanType, funcs, states, options, schedule; id = nothing)

Build a plan of type `PlanType` (`Plan` or `ThreadedCompositeAlgorithm`) from parsed
constructor input: its children `funcs`, their intervals or repeats `schedule`, and its route/share wiring taken from
`options`. Child-scoped wiring (`LocalPlanOption`) is split per child; plain routes and shares are stored on the plan.
The plan keeps its `states` and its other options; `resolve` wraps it in a `LoopAlgorithm`.

`parse_la_input` above and the DSL (`_dsl_build_loopalgorithm`) both end here.
"""
Base.@nospecializeinfer LoopAlgorithm(PlanType::Type{<:AbstractPlan}, @nospecialize(funcs::Tuple), @nospecialize(states::Tuple), @nospecialize(options::Tuple), @nospecialize(schedule); id = nothing) =
    _build_plan(PlanType, funcs, states, options, schedule, id)

# Untyped (`@nospecialize`): construction runs once per plan, usually at top level, and the values (and their types)
# are only known at run time. A typed body compiled again for every plan type, which includes every new `Unique`
# handle. Only the final struct creation is compiled per type.
Base.@nospecializeinfer function _build_plan(PlanType::Type, @nospecialize(funcs::Tuple), @nospecialize(states::Tuple), @nospecialize(options::Tuple), @nospecialize(schedule), id)
    funcs, states, options, schedule = number_unique_ids((funcs, states, options, schedule))
    namespaces = Tuple(Any[Namespace{nothing}() for _ in 1:length(funcs)])
    funcs, child_wiring = _split_children_and_wiring(funcs, options)
    wiring = PlanWiring(_build_plan_wiring_untyped(options), child_wiring, collect_plan_locals(options))
    plan_options = _drop_wiring_options_untyped(options)
    schedule = store_single_repeats_as_repeat_once(schedule)
    return PlanType{typeof(funcs), typeof(schedule), typeof(namespaces), typeof(wiring), id, typeof(states), typeof(plan_options)}(funcs, schedule, namespaces, wiring, states, plan_options)
end


"""
    _build_plan_typed(PlanType, funcs, states, options, schedule, id)

Typed version of `_build_plan`, with the same result. Specialized on the argument types, so the type of the built plan
is known to the compiler when the input types are (useful when plans are built inside functions, many times).

Not used: construction runs on values whose types are only known at run time, and a typed body is compiled again for
every plan type, which includes every new `Unique` handle (about 175 ms per re-run of the benchmark block in
`perf/snapshots`). Kept for a typed construction path.
"""
function _build_plan_typed(::Type{PlanType}, funcs::F, states::Tuple, options::Tuple, schedule, id) where {PlanType<:AbstractPlan, F<:Tuple}
    namespaces = ntuple(_ -> Namespace{nothing}(), length(funcs))
    funcs, child_wiring = _split_children_and_wiring(funcs, options)
    wiring = PlanWiring(_build_plan_wiring(options), child_wiring, collect_plan_locals(options))
    plan_options = _drop_wiring_options(options)
    schedule = store_single_repeats_as_repeat_once(schedule)
    return PlanType{typeof(funcs), typeof(schedule), typeof(namespaces), typeof(wiring), id, typeof(states), typeof(plan_options)}(funcs, schedule, namespaces, wiring, states, plan_options)
end


"""
    setup_registry(las...) -> NameSpaceRegistry

The registry of all algorithms and states in the loop algorithms `las`: per loop algorithm its states (`flat_states`,
each with multiplier 1), then its algorithms (`flat_funcs`) with their multipliers (`flat_multipliers`), added to one
`RegistryBuilder`.
"""
function setup_registry(las...)
    builder = RegistryBuilder()
    for la in las
        for state in flat_states(la)
            add!(builder, state, 1)
        end
        for (algo, multiplier) in zip(flat_funcs(la), flat_multipliers(la))
            add!(builder, algo, multiplier)
        end
    end
    return registry(builder)
end

@inline _stored_schedule_spec(la::Plan) = getschedule(la)
@inline _stored_schedule_spec(la::LoopAlgorithm) = _stored_schedule_spec(getplan(la))

@inline _constructor_type(::Plan) = Plan
@inline _constructor_type(la::LoopAlgorithm) = _constructor_type(getplan(la))

"""
Return the option tuple needed to rebuild a loop algorithm without changing route scope.

Plan nodes store local route/share wiring in child-aligned buckets. Constructor
rebuilds need those buckets rehydrated as `LocalPlanOption` values; otherwise an
edit such as `rename` or `addalgo` would flatten local routes into top-level
routes and change execution semantics.
"""
@inline _stored_constructor_options(la::LA) where {LA<:LoopSpec} = (collect_wiring(la)..., getoptions(la)...)
@inline _stored_constructor_options(la::Plan) = (collect_scoped_wiring(la)..., getoptions(la)...)
@inline _stored_constructor_options(la::LoopAlgorithm) = _stored_constructor_options(getplan(la))

@inline function _rebuild_loopalgorithm(
    la::LA;
    funcs = getalgos(la),
    states = getstates(la),
    options = _stored_constructor_options(la),
    schedule_spec = _stored_schedule_spec(la),
) where {LA<:LoopSpec}
    LoopAlgorithm(_constructor_type(la), funcs, states, options, schedule_spec; id = getid(la))
end
