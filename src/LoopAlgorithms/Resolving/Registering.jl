#=
Steps 1 and 2 of `resolve`: the registry of a plan, and the plan keyed; the registry is then attached to the root
wrapper (`_attach_registry`, Accessors.jl; step 1 leaves no nested wrappers).

`setup_registry_and_keyed_algos(la) -> (registry, keyed la)` (GeneratedCode/RegistrySetup.jl) walks the whole tree of
`la` once: the states first, then every algorithm, each added to one `RegistryBuilder` with its multiplier. Each
child of a plan is then stored raw (without its identity wrapper), and its key goes into the plan's `namespaces`.

The walk works on values (`setup_registry_from_values`), or on the plan's type, with `KnownByType`s
(`setup_registry_code`): the code generated from that only reads the algorithms out of the plan.
=#

"""
    setup_registry_from_values(la) -> (registry, keyed la)

The registry of the whole tree of `la`, and `la` with every child replaced by its raw algorithm and its key recorded in
its plan's `namespaces`, worked out on the values (`add_tree!`, then `registry`). Compiled once, not per plan. Used
when the layout cannot be worked out from the plan's type (see `setup_registry_code`).
"""
@noinline Base.@nospecializeinfer function setup_registry_from_values(@nospecialize(la::LoopAlgorithm))
    builder = RegistryBuilder()
    keyed_la = add_tree!(builder, la)
    return registry(builder), keyed_la
end

"""
    setup_registry_code(LA) -> Expr

The body of `setup_registry_and_keyed_algos` for a `LoopAlgorithm` of type `LA` (the argument is named `la`): code that
returns `(registry, keyed la)` as `setup_registry_from_values(la)` does. The same walk, run on `LA`'s types, decides the
whole registry and the keyed plan; the code returned only reads the algorithms out of `la` and puts them in place,
creating the multipliers and lookup tables anew. When a step needs the values (`NeedsValues`), or the walk throws (an
error the values would give too), the code returned calls `setup_registry_from_values(la)`.
"""
Base.@nospecializeinfer function setup_registry_code(@nospecialize(LA))
    builder = RegistryBuilder()
    keyed = try
        add_tree!(builder, KnownByType(LA, :la))
    catch
        return :(setup_registry_from_values(la))
    end
    return Expr(:tuple, registry_code(builder), keyed.expr)
end

###############################################################################
# The walk
###############################################################################

"""
    add_tree!(builder, la) -> keyed la

Adds the whole tree of the `LoopAlgorithm` `la` to `builder`: its states first (`add_states!`), then its algorithms
(`add_children!`). Returns `la` with its plan keyed. `la` can be a `KnownByType`.
"""
Base.@nospecializeinfer function add_tree!(b::RegistryBuilder, @nospecialize(la))
    add_states!(b, la)
    plan = add_children!(b, plan_of(la), 1.0)
    return with_fields(la, (:plan,), (plan,))
end

"""
    add_states!(builder, la)

Adds the states of `la` and of every plan nested in it (not those inside handles) to `builder`, each with multiplier 1,
in the order of `flat_states`. States belong to the context, not to a step, so they are registered once and first.
"""
Base.@nospecializeinfer function add_states!(b::RegistryBuilder, @nospecialize(la))
    type_of(la) <: LoopSpec || return nothing
    # Tuples are read with `getfield`, not iterated: iterating compiles once per tuple type.
    states = states_of(la)
    if type_of(states) <: Tuple
        for i in 1:nfields_of(states)
            add!(b, field_of(states, i), 1)
        end
    elseif type_of(states) !== Nothing
        add!(b, states, 1)
    end
    children = children_of(la)
    for i in 1:nfields_of(children)
        add_states!(b, require_concrete(field_of(children, i)))
    end
    return nothing
end

"""
    add_children!(builder, node, multiplier) -> keyed node

Adds the children of a plan node to `builder`, first to last (`add_child!`). Each child's multiplier (how often it runs
per root step) is `multiplier` times its own interval/repeat factor. Returns the plan with raw children and per child its
context name as a `Namespace` type (`Namespace{:Counter_1}`, or `Namespace{nothing}` for a nested plan) in its
`namespaces`. Only plans get here: `add_child!` unwraps nested wrappers.
"""
Base.@nospecializeinfer function add_children!(b::RegistryBuilder, @nospecialize(node), @nospecialize(multiplier))
    funcs = children_of(node)
    mults = multipliers_of(node)
    n = nfields_of(funcs)
    raws = Vector{Any}(undef, n)
    namespaces = Vector{Any}(undef, n)
    for i in 1:n
        raws[i], namespaces[i] = add_child!(b, field_of(funcs, i), multiplier * getfield(mults, i))
    end
    return with_fields(node, (:funcs, :namespaces), (tuple_of(raws, node), tuple_of(namespaces, node)))
end

"""
    add_child!(builder, child, multiplier) -> (raw child, namespace)

Adds one child to `builder`. Returns the child as its plan stores it afterwards, and its context name as a
`Namespace`: a call (`Callable`) has no identity and is not registered (its `fixed_namespace`); a nested plan (also
one wrapped in a `LoopAlgorithm` or `FinalizedAlgorithm`, or given a name, which is dropped) introduces no namespace and
has its children added instead (`_unwrap_nested_plan`); any other algorithm or state is keyed by the registry (`add!`)
and stored raw, without its identity wrapper.
"""
Base.@nospecializeinfer function add_child!(b::RegistryBuilder, @nospecialize(child), @nospecialize(multiplier))
    T = type_of(require_concrete(child))
    if T <: Callable
        # On types: every call's `fixed_namespace`.
        name = child isa KnownByType ? _CALLS_NAMESPACE : fixed_namespace(child)
        return child, constant_like(Core.apply_type(Namespace, name)(), child)
    end
    if T <: LoopSpec
        # A nested `FinalizedAlgorithm` has its final step dropped with a warning: only on the values.
        T <: FinalizedAlgorithm && child isa KnownByType && throw(NeedsValues())
        inner = T <: LoopAlgorithm ? plan_of(child) : T <: FinalizedAlgorithm ? _unwrap_nested_plan(child) : child
        return add_children!(b, inner, multiplier), constant_like(Namespace{nothing}(), child)
    end
    # A named nested plan. Construction rejects `:name => plan`, but `IdentifiableAlgo(plan, :name)` and
    # `insert(la, i, :name => plan)` get here; the name is dropped and the plan is added as an unnamed one.
    # TODO (TODO.md, "named plans as context slices"): record the name here as `:name => (child SCKeys...)`.
    if T <: AbstractIdentifiableAlgo{<:LoopSpec}
        child isa KnownByType && !(T <: IdentifiableAlgo) && throw(NeedsValues())
        return add_child!(b, child isa KnownByType ? field_of(child, :func) : getalgo(child), multiplier)
    end
    keyed = add!(b, child, multiplier)
    raw = child isa KnownByType ? field_of(keyed, :func) : getalgo(keyed)
    return raw, constant_like(Core.apply_type(Namespace, key_of(keyed))(), child)
end

"""
Return the plan of a nested child: a plan as it is, the plan inside a `LoopAlgorithm`, or the plan inside a
`FinalizedAlgorithm`, whose final step is dropped with a warning (it is root-only, as the constructor does). `insert`
does not go through the constructor's parsing, so either wrapper can reach this point.
"""
_unwrap_nested_plan(plan::AbstractPlan) = plan
_unwrap_nested_plan(la::LoopAlgorithm) = getplan(la)
_unwrap_nested_plan(fa::FinalizedAlgorithm) = _unwrap_nested_plan(_strip_nested_finalized_algorithm(fa))

###############################################################################
# The parts of a plan the walk reads
###############################################################################
#=
From a value or from a `KnownByType`. On types, only `LoopAlgorithm` wrappers and the plan types whose children,
states and multipliers are known to be their fields and type (`Routine`, `CompositeAlgorithm`) are read; any other
throws `NeedsValues`.
=#
const FieldPlan = Union{Routine, CompositeAlgorithm}

"""The plan inside the `LoopAlgorithm` `la` (`getplan`)."""
plan_of(@nospecialize(la)) = la isa KnownByType ? require_concrete(field_of(la, :plan)) : getplan(la)

"""The children of `la` (`getalgos`)."""
Base.@nospecializeinfer function children_of(@nospecialize(la))
    la isa KnownByType || return getalgos(la)
    la.type <: LoopAlgorithm && return children_of(plan_of(la))
    la.type <: FieldPlan || throw(NeedsValues())
    return require_concrete(field_of(la, :funcs))
end

"""The states of `la` (`getstates`)."""
Base.@nospecializeinfer function states_of(@nospecialize(la))
    la isa KnownByType || return getstates(la)
    la.type <: LoopAlgorithm && return states_of(plan_of(la))
    la.type <: FieldPlan || throw(NeedsValues())
    return require_concrete(field_of(la, :states))
end

"""How often each child of `la` runs per run of `la` (`multipliers`), a tuple of numbers."""
Base.@nospecializeinfer function multipliers_of(@nospecialize(la))
    la isa KnownByType || return multipliers(la)
    la.type <: FieldPlan || throw(NeedsValues())
    return multipliers(la.type)
end
