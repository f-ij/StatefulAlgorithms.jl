"""Return non-wiring options that must stay on the `LoopAlgorithm` wrapper."""
function _root_loop_options(options::Options) where {Options<:Tuple}
    root_options = Any[]

    # Constructor-only filtering. Keep this as a plain loop so large DSL route
    # lists do not compile one recursive tuple-builder method per option.
    for option in options
        option isa AbstractWiring && continue
        push!(root_options, option)
    end
    return Tuple(root_options)
end

"""Append non-wiring options to `root_options` without constructing a large tuple."""
function _append_root_loop_options!(root_options::Vector{Any}, options::Options) where {Options<:Tuple}
    for option in options
        option isa AbstractWiring && continue
        push!(root_options, option)
    end
    return root_options
end

"""Collect root options from a loop tree without materializing plan wiring."""
function _append_plan_tree_root_options!(root_options::Vector{Any}, la::LA) where {LA<:AbstractLoopAlgorithm}
    plan = if la isa LoopAlgorithm
        _append_root_loop_options!(root_options, getoptions(la))
        getplan(la)
    else
        la
    end

    # Concrete executable plans store only plan wiring locally, so do not call
    # `getoptions(plan)` here. That would rebuild all route/share options just
    # to discard them as non-root options.
    for child in getalgos(plan)
        child isa AbstractLoopAlgorithm && _append_plan_tree_root_options!(root_options, child)
    end
    return root_options
end

"""Return non-wiring options stored anywhere in an unresolved loop tree."""
function _root_loop_options(la::LA) where {LA<:LoopAlgorithm}
    root_options = Any[]
    _append_plan_tree_root_options!(root_options, la)
    return Tuple(root_options)
end

"""Collect plan-wide route/share wiring into a `Wiring` value."""
@inline function _plan_wiring(options::Options) where {Options<:Tuple}
    routes = typefilter(Route, options)
    shares = typefilter(Share, options)
    return Wiring(routes, shares)
end

"""Return route/share wiring wrapped by a child-scoped plan option."""
@inline _wrapped_plan_wiring(option::LocalPlanOption) = getfield(option, :option)

"""Return whether a child type is addressed by a symbol endpoint."""
function _child_matches_endpoint_match(::Type{Child}, endpoint_match::Symbol) where {Child}
    Child <: AbstractIdentifiableAlgo || return false
    return getkey(Child) == endpoint_match
end

"""Return whether a child type is addressed by a type matcher identity."""
function _child_matches_endpoint_match(::Type{Child}, ::Type{<:TypeMatcher{Target}}) where {Child, Target}
    if Child <: AbstractIdentifiableAlgo
        child_algo = algotype(Child)
        return child_algo == Target || (child_algo isa Type && Target isa Type && child_algo <: Target)
    end
    return Child == Target || (Target isa Type && Child <: Target)
end

"""Return whether a child type is addressed by a matcher identity."""
function _child_matches_endpoint_match(::Type{Child}, endpoint_match::Type{<:AbstractMatcher}) where {Child}
    Child <: AbstractIdentifiableAlgo || return false
    return _matches_endpoint_match(match_by(Child), endpoint_match)
end

"""Return whether a child value is addressed by an endpoint identity."""
@inline _child_matches_endpoint_match(child, endpoint_match) = _child_matches_endpoint_match(typeof(child), endpoint_match)

function _scoped_wiring_matches_child_type(::Type{Child}, ::Type{Owner}, ::Type{Option}) where {Child, Owner, Option}
    if Option <: Route
        return _child_matches_endpoint_match(Child, to_match_by(Option))
    end
    if Owner === Any || Owner === DataType || Owner === UnionAll
        return false
    end
    return match(Child, Owner)
end

@generated function _scoped_wiring_matches_child(::Val{I}, funcs::Funcs, ::LocalPlanOption{Owner, Option}) where {I, Funcs<:Tuple, Owner, Option}
    I > fieldcount(Funcs) && return :(Val(false))
    _scoped_wiring_matches_child_type(fieldtype(Funcs, I), Owner, Option) && return :(Val(true))
    if !(Option <: Route)
        return :(Val(:runtime))
    end
    return :(Val(false))
end

@inline _push_child_wiring_option(::Val{true}, idx, funcs, option::LocalPlanOption, tail::Tail) where {Tail<:Tuple} =
    (_wrapped_plan_wiring(option), tail...)

@inline _push_child_wiring_option(::Val{false}, idx, funcs, option::LocalPlanOption, tail::Tail) where {Tail<:Tuple} = tail

@inline function _push_child_wiring_option(::Val{:runtime}, idx::Val{I}, funcs::Funcs, option::LocalPlanOption, tail::Tail) where {I, Funcs<:Tuple, Tail<:Tuple}
    child = getfield(funcs, I)
    owner = getfield(option, :owner)
    if match(child, owner)
        return (_wrapped_plan_wiring(option), tail...)
    end

    scoped_wiring = _wrapped_plan_wiring(option)
    if scoped_wiring isa Share
        if _child_matches_endpoint_match(child, first_match_by(scoped_wiring)) ||
           _child_matches_endpoint_match(child, second_match_by(scoped_wiring))
            return (scoped_wiring, tail...)
        end
    end
    return tail
end

@inline function _wiring_options_for_child(idx::Val{I}, funcs::Funcs, options::Options) where {I, Funcs<:Tuple, Options<:Tuple}
    isempty(options) && return ()
    tail = _wiring_options_for_child(idx, funcs, Base.tail(options))
    option = getfield(options, 1)
    return _wiring_options_for_child(idx, funcs, option, tail)
end

@inline _wiring_options_for_child(idx, funcs, option::LocalPlanOption, tail::Tail) where {Tail<:Tuple} =
    _push_child_wiring_option(_scoped_wiring_matches_child(idx, funcs, option), idx, funcs, option, tail)

@inline _wiring_options_for_child(idx, funcs, option, tail::Tail) where {Tail<:Tuple} = tail

"""Return the concrete `Wiring` bucket for one child position."""
@inline function _child_wiring_bucket(options::Options) where {Options<:Tuple}
    routes = typefilter(Route, options)
    shares = typefilter(Share, options)
    return Wiring(routes, shares)
end

"""Return the wiring value passed to one child before registry resolution."""
@inline function _child_wiring_for_child(child, bucket::Wiring)
    return bucket
end

"""Return nested plan wiring for loop-plan children."""
@inline function _child_wiring_for_child(child::LA, bucket::Wiring) where {LA<:AbstractLoopAlgorithm}
    isempty(bucket) || error("Child-scoped wiring $(bucket) was assigned to nested plan child $(child). Attach the route/share to a concrete child inside the nested plan.")
    return getwiring(child)
end

"""Return nested plan wiring for identifiable loop-plan children."""
@inline function _child_wiring_for_child(child::IA, bucket::Wiring) where {F<:AbstractLoopAlgorithm, IA<:AbstractIdentifiableAlgo{F}}
    isempty(bucket) || error("Child-scoped wiring $(bucket) was assigned to nested plan child $(child). Attach the route/share to a concrete child inside the nested plan.")
    return getwiring(getalgo(child))
end

"""Return whether a child value receives one runtime-scoped wiring option."""
function _runtime_scoped_wiring_matches_child(child, option::LocalPlanOption)
    scoped_wiring = _wrapped_plan_wiring(option)
    if scoped_wiring isa Route
        return _child_matches_endpoint_match(child, to_match_by(scoped_wiring))
    end

    if match(child, getfield(option, :owner))
        return true
    end

    if scoped_wiring isa Share
        return _child_matches_endpoint_match(child, first_match_by(scoped_wiring)) ||
            _child_matches_endpoint_match(child, second_match_by(scoped_wiring))
    end
    return false
end

"""Construct child wiring without generating an O(children * options) method body."""
function _plan_child_wiring_runtime(funcs::Funcs, options::Options) where {Funcs<:Tuple, Options<:Tuple}
    route_buckets = [Any[] for _ in 1:length(funcs)]
    share_buckets = [Any[] for _ in 1:length(funcs)]

    # Group and validate in one pass. A separate validation scan over concrete
    # `Wiring` tuples made large DSL construction spend seconds in inference.
    for option in options
        option isa LocalPlanOption || continue
        scoped_wiring = _wrapped_plan_wiring(option)
        assigned = false
        for i in eachindex(route_buckets)
            _runtime_scoped_wiring_matches_child(getfield(funcs, i), option) || continue
            if scoped_wiring isa Route
                push!(route_buckets[i], scoped_wiring)
            elseif scoped_wiring isa Share
                push!(share_buckets[i], scoped_wiring)
            end
            assigned = true
        end
        assigned || error("Child-scoped wiring $(option) could not be assigned to any child in plan funcs $(funcs).")
    end

    raw_buckets = ntuple(i -> Wiring(Tuple(route_buckets[i]), Tuple(share_buckets[i])), length(funcs))
    return ntuple(i -> _child_wiring_for_child(getfield(funcs, i), getfield(raw_buckets, i)), length(funcs))
end

"""
Build the child-indexed wiring tuple stored in `PlanWiring`.

For every child position this produces exactly the value that `step!` receives:
a `Wiring(routes, shares)` bucket for concrete children, or a nested
`PlanWiring` for child loop plans.
"""
function _plan_child_wiring(funcs::Funcs, options::Options) where {Funcs<:Tuple, Options<:Tuple}
    return _plan_child_wiring_runtime(funcs, options)
end

#=
Generated child-wiring builder kept here while testing whether constructor-side
specialization is worth it. Early measurements show the runtime builder is
cheaper for large DSL construction, and it still stores concrete wiring in the
constructed plan.

@inline @generated function _plan_child_wiring(funcs::Funcs, options::Options) where {Funcs<:Tuple, Options<:Tuple}
    if fieldcount(Funcs) * fieldcount(Options) > _PLAN_CHILD_WIRING_GENERATED_PRODUCT_LIMIT
        return :(StatefulAlgorithms._plan_child_wiring_runtime(funcs, options))
    end

    runtime_checks = Any[]
    for option_idx in 1:fieldcount(Options)
        option_type = fieldtype(Options, option_idx)
        option_type <: LocalPlanOption || continue
        owner = option_type.parameters[1]
        option = option_type.parameters[2]

        assigned = any(i -> _scoped_wiring_matches_child_type(fieldtype(Funcs, i), owner, option), 1:fieldcount(Funcs))
        runtime_assigned = !(option <: Route)
        if !assigned
            if runtime_assigned
                push!(runtime_checks, quote
                    _candidate_wiring = _wrapped_plan_wiring(getfield(options, $option_idx))
                    _assigned = false
                    for _bucket in _raw_buckets
                        _assigned |= any(==(_candidate_wiring), routes(_bucket)) || any(==(_candidate_wiring), shares(_bucket))
                    end
                    _assigned || error("Child-scoped wiring $(getfield(options, $option_idx)) could not be assigned to any child in plan funcs $(funcs).")
                end)
                continue
            end
            return :(error("Child-scoped wiring $(getfield(options, $option_idx)) could not be assigned to any child in plan funcs $(funcs)."))
        end
    end

    raw_expr = Expr(:tuple, (:(@inline _child_wiring_bucket(@inline _wiring_options_for_child(Val($i), funcs, options))) for i in 1:fieldcount(Funcs))...)
    child_expr = Expr(:tuple, (:(@inline _child_wiring_for_child(getfield(funcs, $i), getfield(_raw_buckets, $i))) for i in 1:fieldcount(Funcs))...)
    if isempty(runtime_checks)
        return quote
            _raw_buckets = $raw_expr
            $child_expr
        end
    end
    return quote
        _raw_buckets = $raw_expr
        $(runtime_checks...)
        $child_expr
    end
end
=#

"""Flatten the raw wiring values stored by a plan for constructor rebuilds."""
@inline function _all_plan_wiring(plan_wiring::Wiring, child_wiring::ChildWiring) where {ChildWiring<:Tuple}
    isempty(child_wiring) && return (routes(plan_wiring)..., shares(plan_wiring)...)
    head = getfield(child_wiring, 1)
    head_values = head isa Wiring ? (routes(head)..., shares(head)...) : ()
    return (routes(plan_wiring)..., shares(plan_wiring)..., head_values..., _all_plan_wiring(Wiring(), Base.tail(child_wiring))...)
end

"""Append wiring values while preserving first occurrence order."""
function _append_unique_wiring_values(values::Tuple, items::Tuple)
    for item in items
        any(==(item), values) || (values = (values..., item))
    end
    return values
end

"""Flatten grouped `Wiring` buckets into route/share values."""
@inline _flatten_wiring_values(wirings::Tuple{}) = ()
@inline function _flatten_wiring_values(wirings::Wirings) where {Wirings<:Tuple}
    head = first(wirings)
    return (routes(head)..., shares(head)..., _flatten_wiring_values(Base.tail(wirings))...)
end

"""Flatten grouped resolved wiring values for inspection-style callers."""
@inline function _all_plan_wiring(grouped::NamedTuple, child_wiring::ChildWiring) where {ChildWiring<:Tuple}
    collected = _flatten_wiring_values(values(grouped))
    isempty(child_wiring) && return collected
    head = getfield(child_wiring, 1)
    if head isa Wiring
        collected = _append_unique_wiring_values(collected, (routes(head)..., shares(head)...))
    end
    return _append_unique_wiring_values(collected, _all_plan_wiring((;), Base.tail(child_wiring)))
end
