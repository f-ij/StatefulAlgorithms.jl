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
    end
    if isnothing(intervals_or_repeats)
        got = isempty(args) ? "no repeats" : repr(first(args))
        construction_error("For routines, please pass the number of repeats after all ProcessAlgorithms as a tuple, even if it's just one repeat, e.g. (10,). Got: ", got)
    end

    ### FLATTEN ###
    if iscomposite(laType)

        processalgos, intervals_or_repeats = flatten_comp_funcs(processalgos, tuple(intervals_or_repeats...))
    end

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
    return LoopAlgorithm(laType, processalgos, pstates, options, intervals_or_repeats)
end

"""
    LoopAlgorithm(PlanType, funcs, states, options, schedule; id = nothing)

Build a plan of type `PlanType` (`CompositeAlgorithm`, `Routine` or `ThreadedCompositeAlgorithm`) from parsed
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
    funcs, states, options, schedule = _number_plan_unique_ids(funcs, states, options, schedule)
    namespaces = Tuple(Any[Namespace{nothing}() for _ in 1:length(funcs)])
    funcs, child_wiring = _plan_children(funcs, options)
    wiring = PlanWiring(_plan_wiring_untyped(options), child_wiring, collect_plan_locals(options))
    plan_options = _non_wiring_untyped(options)
    return PlanType{typeof(funcs), schedule, typeof(namespaces), typeof(wiring), id, typeof(states), typeof(plan_options)}(funcs, schedule, namespaces, wiring, states, plan_options)
end

"""
    _number_plan_unique_ids(funcs, states, options, schedule) -> (funcs, states, options, schedule)

The inputs of a plan with its `Unique` handles numbered (`number_unique_ids`): each nested plan among `funcs` comes
with its own numbers and is one scope; the plan's other children, its states, options and schedule are another.
"""
Base.@nospecializeinfer function _number_plan_unique_ids(@nospecialize(funcs::Tuple), @nospecialize(states::Tuple), @nospecialize(options::Tuple), @nospecialize(schedule))
    nested = Int[i for i in eachindex(funcs) if _is_nested_plan_input(funcs[i])]
    own = Any[funcs[i] for i in eachindex(funcs) if !(i in nested)]
    scopes = Any[(Tuple(own), states, options, schedule)]
    for i in nested
        push!(scopes, funcs[i])
    end
    numbered = number_unique_ids(Tuple(scopes))
    numbered === Tuple(scopes) && return funcs, states, options, schedule
    own_funcs, states, options, schedule = numbered[1]
    out = Vector{Any}(undef, length(funcs))
    o = 0
    for i in eachindex(funcs)
        k = findfirst(==(i), nested)
        out[i] = isnothing(k) ? own_funcs[o += 1] : numbered[k + 1]
    end
    return Tuple(out), states, options, schedule
end

_is_nested_plan_input(@nospecialize(f)) = f isa LoopSpec || (f isa AbstractIdentifiableAlgo && getalgo(f) isa LoopSpec)

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
    funcs, child_wiring = _plan_children(funcs, options)
    wiring = PlanWiring(_plan_wiring(options), child_wiring, collect_plan_locals(options))
    plan_options = _non_wiring(options)
    return PlanType{typeof(funcs), schedule, typeof(namespaces), typeof(wiring), id, typeof(states), typeof(plan_options)}(funcs, schedule, namespaces, wiring, states, plan_options)
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
