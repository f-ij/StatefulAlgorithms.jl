############################################################################################
# 1. Registry
############################################################################################

"""
    setup_registry_and_keyed_algos(la) -> (registry, keyed_la)

The registry of the whole tree of `la`, and `la` with every child replaced by its raw algorithm and its key recorded
in its plan's `namespaces`. Walks the tree once collecting the registry as plain values (`RegistryDraft`), then
builds the registry once (`build_registry`); compiled once, not per plan.
"""
Base.@nospecializeinfer function setup_registry_and_keyed_algos(@nospecialize(la::LoopAlgorithm))
    draft = RegistryDraft()
    keyed_la = draft_add_loopalgorithm!(draft, la)
    return build_registry(draft), keyed_la
end

"""
    draft_add_loopalgorithm!(draft, la) -> keyed_la

Add the states of the whole tree of `la` to `draft` (first, each with multiplier 1), then its algorithms, and return
`la` with its plan keyed (see `draft_add_children!`).
"""
Base.@nospecializeinfer function draft_add_loopalgorithm!(draft::RegistryDraft, @nospecialize(la::LoopAlgorithm))
    # States are context-owned entries, registered first; in the order of `flat_states`.
    states = Any[]
    _collect_states!(states, la)
    for s in states
        draft_add!(draft, s, 1)
    end
    plan = draft_add_children!(draft, getplan(la), 1.0)
    return _with_fields(la, (:plan,), (plan,))
end

"""Push the states of `la` and of every plan nested in it (not inside handles) to `out`, in the order of `flat_states`."""
Base.@nospecializeinfer function _collect_states!(out::Vector{Any}, @nospecialize(la))
    la isa LoopSpec || return out
    # Tuples are read with `getfield`, not iterated: iterating compiles once per tuple type.
    states = getstates(la)
    if states isa Tuple
        for i in 1:nfields(states)
            push!(out, getfield(states, i))
        end
    elseif !isnothing(states)
        push!(out, states)
    end
    children = getalgos(la)
    for i in 1:nfields(children)
        _collect_states!(out, getfield(children, i))
    end
    return out
end

"""
    draft_add_children!(draft, la, multiplier) -> keyed plan

Add the children of a plan node to `draft`, first to last. Each child's multiplier (how often it runs per root step)
is `multiplier` times its own interval/repeat factor. Returns the plan with raw children and per child its context
name as a `Namespace` type (`Namespace{:Counter_1}`, or `Namespace{nothing}` for a nested plan) in its `namespaces`.
"""
Base.@nospecializeinfer function draft_add_children!(draft::RegistryDraft, @nospecialize(la::AbstractPlan), @nospecialize(multiplier))
    funcs = getalgos(la)
    mults = multipliers(la)
    n = nfields(funcs)
    raws = Vector{Any}(undef, n)
    namespaces = Vector{Any}(undef, n)
    for i in 1:n
        raws[i], namespaces[i] = draft_add_child!(draft, getfield(funcs, i), multiplier * getfield(mults, i))
    end
    return _with_fields(_with_fields(la, (:funcs,), (Tuple(raws),)), (:namespaces,), (Tuple(namespaces),))
end

"""
    draft_add_child!(draft, child, multiplier) -> (raw, namespace)

Add one child to `draft`. Returns the child as its plan stores it afterwards and its context name as a `Namespace`:
a call (`Callable`) has no identity and is not registered (its `fixed_namespace`); a nested plan (also one wrapped in
a `LoopAlgorithm` or `FinalizedAlgorithm`, or given a name, which is dropped) introduces no namespace and has its
children added instead (`_unwrap_nested_plan`); any other algorithm or state is keyed by the registry and stored raw,
without its identity wrapper.
"""
Base.@nospecializeinfer function draft_add_child!(draft::RegistryDraft, @nospecialize(child), @nospecialize(multiplier))
    child isa Callable && return child, Core.apply_type(Namespace, fixed_namespace(child))()
    child isa LoopSpec && return draft_add_children!(draft, _unwrap_nested_plan(child), multiplier), Namespace{nothing}()
    # A named nested plan. Construction rejects `:name => plan`, but `IdentifiableAlgo(plan, :name)` and
    # `insert(la, i, :name => plan)` get here; the name is dropped.
    # TODO (TODO.md, "named plans as context slices"): record the name here as `:name => (child SCKeys...)`.
    child isa AbstractIdentifiableAlgo{<:LoopSpec} && return draft_add_child!(draft, getalgo(child), multiplier)
    keyed = draft_add!(draft, child, multiplier)
    return getalgo(keyed), Core.apply_type(Namespace, getkey(keyed))()
end

"""
Return the plan of a nested child: a plan as it is, the plan inside a `LoopAlgorithm`, or the plan inside a
`FinalizedAlgorithm`, whose final step is dropped with a warning (it is root-only, as the constructor does). `insert`
does not go through the constructor's parsing, so either wrapper can reach this point.
"""
_unwrap_nested_plan(plan::AbstractPlan) = plan
_unwrap_nested_plan(la::LoopAlgorithm) = getplan(la)
_unwrap_nested_plan(fa::FinalizedAlgorithm) = _unwrap_nested_plan(_strip_nested_finalized_algorithm(fa))

############################################################################################
# 2. Attaching the registry: `_attach_registry` on the root (Accessors.jl; step 1 left no nested wrappers)
############################################################################################
