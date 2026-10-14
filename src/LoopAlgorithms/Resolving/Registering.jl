############################################################################################
# 1. Registry
############################################################################################

# `setup_registry_and_keyed_algos(la) -> (registry, keyed_la)`, the registry of the whole tree of `la` and `la` keyed,
# is a generated function (GeneratedCode/Preparation.jl): it works out the layout from the plan's type with the
# functions below (`_registry_setup_body`), and falls back to `_setup_registry_at_runtime` when that needs values.

"""
    _setup_registry_at_runtime(la) -> (registry, keyed_la)

The registry of the whole tree of `la`, and `la` with every child replaced by its raw algorithm and its key recorded
in its plan's `namespaces`, worked out on the values: walks the tree once collecting the registry as plain values
(`RegistryDraft`), then builds the registry once (`build_registry`). Compiled once, not per plan. Used when the
layout cannot be worked out from the plan's type (see `_registry_setup_body`).
"""
Base.@nospecializeinfer function _setup_registry_at_runtime(@nospecialize(la::LoopAlgorithm))
    draft = RegistryDraft()
    keyed_la = draft_add_loopalgorithm!(draft, la)
    return build_registry(draft), keyed_la
end

"""
    _registry_setup_body(LA) -> Expr

The body of `setup_registry_and_keyed_algos` for a `LoopAlgorithm` of type `LA` (the argument is named `la`): the
same walk and draft as `_setup_registry_at_runtime`, run on `LA`'s types, decide the whole registry and the keyed
plan; the code returned only reads the algorithms out of `la` and puts them in place, building the multipliers and
lookup tables anew. When a step needs the values (see `_NeedsValues`), or the walk throws (an error the values
would give too), the code returned is a call to `_setup_registry_at_runtime(la)`.
"""
Base.@nospecializeinfer function _registry_setup_body(@nospecialize(LA))
    draft = RegistryDraft()
    keyed = try
        draft_add_loopalgorithm!(draft, _GenItem(LA, :la))
    catch
        return :(_setup_registry_at_runtime(la))
    end
    return Expr(:tuple, registry_expr(draft), keyed.ex)
end

"""
    draft_add_loopalgorithm!(draft, la) -> keyed_la

Add the states of the whole tree of `la` to `draft` (first, each with multiplier 1), then its algorithms, and return
`la` with its plan keyed (see `draft_add_children!`). `la` can be a `_GenItem` (see `RegistryDraft`).
"""
Base.@nospecializeinfer function draft_add_loopalgorithm!(draft::RegistryDraft, @nospecialize(la))
    # States are context-owned entries, registered first; in the order of `flat_states`.
    states = Any[]
    _collect_states!(states, la)
    for s in states
        draft_add!(draft, s, 1)
    end
    plan = draft_add_children!(draft, _iplan(la), 1.0)
    return _with_fields(la, (:plan,), (plan,))
end

#=
The parts of a plan the walk reads, from a value or from a `_GenItem`. On types, only `LoopAlgorithm` wrappers and
the plan types whose children, states and multipliers are known to be their fields and type (`Routine`,
`CompositeAlgorithm`) are read; any other throws `_NeedsValues`.
=#
const _FieldPlan = Union{Routine, CompositeAlgorithm}
"""The plan inside the `LoopAlgorithm` `la` (`getplan`)."""
_iplan(@nospecialize(la)) = la isa _GenItem ? _iconcrete(_ifield(la, :plan)) : getplan(la)
"""The children of `la` (`getalgos`)."""
Base.@nospecializeinfer function _ialgos(@nospecialize(la))
    la isa _GenItem || return getalgos(la)
    la.T <: LoopAlgorithm && return _ialgos(_iplan(la))
    la.T <: _FieldPlan || throw(_NeedsValues())
    return _iconcrete(_ifield(la, :funcs))
end
"""The states of `la` (`getstates`)."""
Base.@nospecializeinfer function _istates(@nospecialize(la))
    la isa _GenItem || return getstates(la)
    la.T <: LoopAlgorithm && return _istates(_iplan(la))
    la.T <: _FieldPlan || throw(_NeedsValues())
    return _iconcrete(_ifield(la, :states))
end
"""How often each child of `la` runs per run of `la` (`multipliers`), a tuple of numbers."""
Base.@nospecializeinfer function _imultipliers(@nospecialize(la))
    la isa _GenItem || return multipliers(la)
    la.T <: _FieldPlan || throw(_NeedsValues())
    return multipliers(la.T)
end

"""Push the states of `la` and of every plan nested in it (not inside handles) to `out`, in the order of `flat_states`."""
Base.@nospecializeinfer function _collect_states!(out::Vector{Any}, @nospecialize(la))
    _itemtype(la) <: LoopSpec || return out
    # Tuples are read with `getfield`, not iterated: iterating compiles once per tuple type.
    states = _istates(la)
    if _itemtype(states) <: Tuple
        for i in 1:_infields(states)
            push!(out, _ifield(states, i))
        end
    elseif _itemtype(states) !== Nothing
        push!(out, states)
    end
    children = _ialgos(la)
    for i in 1:_infields(children)
        _collect_states!(out, _iconcrete(_ifield(children, i)))
    end
    return out
end

"""
    draft_add_children!(draft, la, multiplier) -> keyed plan

Add the children of a plan node to `draft`, first to last. Each child's multiplier (how often it runs per root step)
is `multiplier` times its own interval/repeat factor. Returns the plan with raw children and per child its context
name as a `Namespace` type (`Namespace{:Counter_1}`, or `Namespace{nothing}` for a nested plan) in its `namespaces`.
"""
Base.@nospecializeinfer function draft_add_children!(draft::RegistryDraft, @nospecialize(la), @nospecialize(multiplier))
    funcs = _ialgos(la)
    mults = _imultipliers(la)
    n = _infields(funcs)
    raws = Vector{Any}(undef, n)
    namespaces = Vector{Any}(undef, n)
    for i in 1:n
        raws[i], namespaces[i] = draft_add_child!(draft, _ifield(funcs, i), multiplier * getfield(mults, i))
    end
    return _with_fields(la, (:funcs, :namespaces), (_ituple(raws, la), _ituple(namespaces, la)))
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
    T = _itemtype(_iconcrete(child))
    if T <: Callable
        # On types: every call's `fixed_namespace`.
        name = child isa _GenItem ? _CALLS_NAMESPACE : fixed_namespace(child)
        return child, _iconst(Core.apply_type(Namespace, name)(), child)
    end
    if T <: LoopSpec
        # A nested `FinalizedAlgorithm` has its final step dropped with a warning: only on the values.
        T <: FinalizedAlgorithm && child isa _GenItem && throw(_NeedsValues())
        inner = T <: LoopAlgorithm ? _iplan(child) : T <: FinalizedAlgorithm ? _unwrap_nested_plan(child) : child
        return draft_add_children!(draft, inner, multiplier), _iconst(Namespace{nothing}(), child)
    end
    # A named nested plan. Construction rejects `:name => plan`, but `IdentifiableAlgo(plan, :name)` and
    # `insert(la, i, :name => plan)` get here; the name is dropped and the plan is added as an unnamed one.
    # TODO (TODO.md, "named plans as context slices"): record the name here as `:name => (child SCKeys...)`.
    if T <: AbstractIdentifiableAlgo{<:LoopSpec}
        child isa _GenItem && !(T <: IdentifiableAlgo) && throw(_NeedsValues())
        return draft_add_child!(draft, child isa _GenItem ? _ifield(child, :func) : getalgo(child), multiplier)
    end
    keyed = draft_add!(draft, child, multiplier)
    raw = child isa _GenItem ? _ifield(keyed, :func) : getalgo(keyed)
    return raw, _iconst(Core.apply_type(Namespace, _draft_getkey(keyed))(), child)
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
