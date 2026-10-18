############################################################################################
# 1. Registry
############################################################################################

"""
Add every state and algorithm of the tree to `registry` (a new one by default) and return it with the keyed plan.
"""
function setup_registry_and_keyed_algos(la::LoopAlgorithm, registry::R = NameSpaceRegistry()) where {R<:NameSpaceRegistry}
    # States are context-owned entries. They are registered first, as `setup_registry` (Setup.jl) also does,
    # so both give the same registry ordering.
    states = flat_states(la)
    multipliers = ntuple(i -> 1, length(states))
    registry = addall(registry, states, multipliers)

    registry, named_plan = add_algos_to_registry(registry, getplan(la), 1.0)
    return registry, setfield(la, :plan, named_plan)
end

"""
Register the children of a plan node. Each child's multiplier (how often it runs per root step)
is the parent's times its own interval/repeat factor. Returns the plan with raw children and
their namespaces.
"""
function add_algos_to_registry(registry::R, la::LA, multiplier) where {R<:NameSpaceRegistry, LA<:AbstractPlan}
    funcs = getalgos(la)
    algo_multipliers = tuplemap(m -> multiplier * m, multipliers(la))
    registry, raw_funcs, namespaces = add_algo_tuple_to_registry(registry, funcs, algo_multipliers)
    return registry, setfield(rebuild_loopalgorithm_funcs(la, raw_funcs), :namespaces, namespaces)
end

"""
    add_algo_tuple_to_registry(registry, funcs, multipliers) -> (registry, raw_funcs, namespaces)

Register the children of one plan, first to last, each with its multiplier. Returns the registry with the children
added, the children as the plan stores them afterwards (a plain algorithm without its identifiable wrapper, or a
nested plan whose own children are registered too), and per child its context name as a `Namespace` type
(`Namespace{:Counter_1}`, or `Namespace{nothing}` for a nested plan).
"""
function add_algo_tuple_to_registry(registry::R, funcs::F, multipliers::M) where {R<:NameSpaceRegistry, F<:Tuple, M<:Tuple}
    # Written as recursion over the front of the tuple that adds the last child to the registry it gets back, so that
    # the registry's type stays known: it grows with every child, and recursing over the tail instead (passing the
    # growing registry down as an argument) makes Julia give up and use plain `NameSpaceRegistry`. Here the arguments
    # only get shorter, which works for any number of children.
    reg, raws, names = add_algo_tuple_to_registry(registry, Base.front(funcs), Base.front(multipliers))
    reg, raw, name = add_algo_to_registry(reg, last(funcs), last(multipliers))
    return reg, (raws..., raw), (names..., name)
end
add_algo_tuple_to_registry(registry::R, ::Tuple{}, ::Tuple{}) where {R<:NameSpaceRegistry} = registry, (), ()

# An algorithm or state: the registry assigns its key. The plan keeps the raw algorithm and the
# key as its namespace, so the plan's types do not depend on identity wrappers.
function add_algo_to_registry(registry::R, algo::A, multiplier) where {R<:NameSpaceRegistry, A}
    registry, keyed_algo = add(registry, algo, multiplier)
    return registry, getalgo(keyed_algo), Namespace{getkey(keyed_algo)}()
end

"""Plain function calls have no state or identity: not registered, all in their `fixed_namespace`."""
add_algo_to_registry(registry::R, ex::EX, multiplier) where {R<:NameSpaceRegistry, EX<:Callable} =
    registry, ex, Namespace{fixed_namespace(ex)}()

# A nested plan introduces no namespace: register its children instead, which carry theirs.
# `Namespace{nothing}` only fills the plan's slot in `namespaces`.
function add_algo_to_registry(registry::R, algo::LA, multiplier) where {R<:NameSpaceRegistry, LA<:LoopSpec}
    registry, plan = add_algos_to_registry(registry, _unwrap_nested_plan(algo), multiplier)
    return registry, plan, Namespace{nothing}()
end

# The same for a nested plan that was given a name. Construction rejects `:name => plan`, but
# `IdentifiableAlgo(plan, :name)` and `insert(la, i, :name => plan)` get here; the name is dropped.
# TODO (TODO.md, "named plans as context slices"): record the name here as `:name => (child SCKeys...)`.
add_algo_to_registry(registry::R, algo::IA, multiplier) where {F<:LoopSpec, R<:NameSpaceRegistry, IA<:AbstractIdentifiableAlgo{F}} =
    add_algo_to_registry(registry, getalgo(algo), multiplier)

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
