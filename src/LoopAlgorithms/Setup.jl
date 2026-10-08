"""Return `true` for loop-constructor children that run or describe runnable children."""
function _is_loop_child_input(arg)
    return arg isa Union{SteppableAlgorithm, AbstractPlan, Type{<:SteppableAlgorithm}, Type{<:AbstractPlan}}
end

"""
Return `true` when an argument belongs in the algorithm section of a loop constructor.

Named state pairs like `:_state => state` are intentionally excluded here so they
fall through to the later ProcessState parsing branch.
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
        elseif arg.second isa ProcessState || arg.second isa Type{<:ProcessState}
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

"""Return `true` when an argument belongs in the ProcessState section."""
@inline isa_processstate_input(arg) = (arg isa ProcessState) || (arg isa Type{<:ProcessState}) || (arg isa Pair && arg.first isa Symbol && (arg.second isa ProcessState || arg.second isa Type{<:ProcessState}))

#TODO: Don't allow Identifiable wrapping of LoopAlgorithms
"""
Call a LoopAlgorithm as:

LoopAlgorithm(  func1, func2, func3, ..., 
                tuple(interval1, interval2, interval3, ...),
                processstate1, processstate2, ..., 
                options1, option2, ...)

Plain `Route` and `Share` options are stored on the top-level plan as global
routing metadata. DSL expansion can pass `LocalPlanOption` values when a
route/share belongs to a specific child plan node. Non-routing options stay on
the `LoopAlgorithm` runtime wrapper.
"""
function parse_la_input(laType::Type{LA}, args...) where {LA<:AbstractPlan}
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
    ######### INTERVALS #########
    # Now we should have intervals/repeats if theres more than one function
    intervals_or_repeats = nothing
    if !isempty(args)
        firstargs = args[1]

        if firstargs isa Tuple
            intervals_or_repeats = _filter_loopalgorithm_specification(firstargs, kept_algos)
            if iscomposite(laType)
                intervals_or_repeats = map(x -> x isa Union{Interval, RunIf} ? x : Interval(x), intervals_or_repeats)
            else
                intervals_or_repeats = map(x -> x isa Lifetime ? x : Repeat(x), intervals_or_repeats)
            end
            args = args[2:end] # Remove the intervals from the arguments list for further processing
        elseif iscomposite(laType)
            intervals_or_repeats = ntuple(_ -> Interval(1), length(processalgos))

        end

    elseif iscomposite(laType)
        intervals_or_repeats = ntuple(_ -> Interval(1), length(processalgos))
    else
        construction_error("For routines, please pass the number of repeats after all ProcessAlgorithms as a tuple, even if it's just one repeat, e.g. (10,). Got: ", firstargs)
    end

    ### FLATTEN ###
    lifted_states = ()
    if iscomposite(laType)
        lifted_states = flattened_states(processalgos)

        processalgos, intervals_or_repeats = flatten_comp_funcs(processalgos, tuple(intervals_or_repeats...))
    end

    ######### PROCESS STATES #########
    pstates = lifted_states
    while true
        el, args = parse_by_func(isa_processstate_input, args...; error = false)
        if isnothing(el)
            break
        else
            if el isa Pair
                state = IdentifiableAlgo(el.second, el.first)
            elseif el isa Union{ProcessState, Type{<:ProcessState}}
                state = IdentifiableAlgo(el)
            else
                state = el
            end
            pstates = tuple(pstates..., state)
        end
    end
    # first_process_states = findfirst(isa_processstate_input, args)
    # last_process_state = nothing
    # pstates = tuple()
    # if !isnothing(first_process_states)
    #     last_process_state = findlast(isa_processstate_input, args)
    #     pstates = args[first_process_states:last_process_state]
    #     @assert all(isa_processstate_input, pstates) "All arguments between the first and last ProcessState must be ProcessStates, but got: $(pstates)"
    #     pstates = map(pstates) do state
    #         if state isa Pair
    #             IdentifiableAlgo(state.second, state.first)
    #         else
    #             IdentifiableAlgo(state)
    #         end
    #     end
    #     args = args[last_process_state + 1:end]
    # end

    options = tuple()
    if !isempty(args)
        options = tuple(args[1:end]...)
        all(x -> x isa Union{AbstractOption, AbstractWiring} || x isa Type{<:Union{AbstractOption, AbstractWiring}}, options) || construction_assert_error("All arguments after the ProcessStates must be options or wiring, but got: ", options)
    end
    options = tuple(collected_options..., options...)
    return LoopAlgorithm(laType, processalgos, pstates, options, intervals_or_repeats)
end

"""
    LoopAlgorithm(PlanType, funcs, states, options, schedule; id = nothing)

Build a plan of type `PlanType` (`CompositeAlgorithm`, `Routine` or `ThreadedCompositeAlgorithm`) from parsed
constructor input: its children `funcs`, their intervals or repeats `schedule`, and its route/share wiring taken from
`options`. Child-scoped wiring (`LocalPlanOption`) is split per child; plain routes and shares are stored on the plan.
The plan is wrapped in a `LoopAlgorithm` only when there are `states` or other options to keep on the wrapper.

`parse_la_input` above and the DSL (`_dsl_build_loopalgorithm`) both end here.
"""
Base.@nospecializeinfer LoopAlgorithm(PlanType::Type{<:AbstractPlan}, @nospecialize(funcs::Tuple), @nospecialize(states::Tuple), @nospecialize(options::Tuple), @nospecialize(schedule); id = nothing) =
    _build_plan(PlanType, funcs, states, options, schedule, id)

# Untyped (`@nospecialize`): construction runs once per plan, usually at top level, and the values (and their types)
# are only known at run time. A typed body compiled again for every plan type, which includes every new `Unique`
# handle. Only the final struct creation is compiled per type.
Base.@nospecializeinfer function _build_plan(PlanType::Type, @nospecialize(funcs::Tuple), @nospecialize(states::Tuple), @nospecialize(options::Tuple), @nospecialize(schedule), id)
    namespaces = Tuple(Any[Namespace{nothing}() for _ in 1:length(funcs)])
    wiring = PlanWiring(_plan_wiring_untyped(options), _plan_child_wiring_runtime(funcs, options))
    plan = PlanType{typeof(funcs), schedule, typeof(namespaces), typeof(wiring), id}(funcs, schedule, namespaces, wiring)
    root_options = _root_loop_options_untyped(options)
    return isempty(states) && isempty(root_options) ? plan : LoopAlgorithm(plan; states, options = root_options, id)
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
    wiring = PlanWiring(_plan_wiring(options), _plan_child_wiring(funcs, options))
    plan = PlanType{typeof(funcs), schedule, typeof(namespaces), typeof(wiring), id}(funcs, schedule, namespaces, wiring)
    root_options = _root_loop_options(options)
    return isempty(states) && isempty(root_options) ? plan : LoopAlgorithm(plan; states, options = root_options, id)
end


"""
Add all algos and states in one or more loop algorithms to a shared registry with
their corresponding multipliers/intervals.
"""
setup_registry(las...) = _setup_registry(las)

function _setup_registry(las::LAS) where {LAS<:Tuple}
    registry = NameSpaceRegistry()
    for la in las
        # First add states with multiplier 1
        states = flat_states(la)
        multipliers = ntuple(i -> 1, length(states))
        registry = addall(registry, states, multipliers)

        # Then add algos with their corresponding multipliers
        all_funcs = @inline flat_funcs(la)
        multipliers = @inline flat_multipliers(la)
        registry = @inline addall(registry, all_funcs, multipliers)
    end

    return registry
end
