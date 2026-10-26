#=
Steps 1 and 2 of `resolve`: the registry of a plan, and the plan keyed; the registry is then attached to the root
wrapper (`_attach_registry`, Accessors.jl; step 1 leaves no nested wrappers).

`build_registry_and_key_plan(la) -> (registry, keyed la)` (GeneratedCode/Registry/Setup.jl) walks the whole tree of
`la` once: the states first, then every algorithm, each added to one `RegistryBuilder` with its multiplier. Each
child of a plan is then stored raw (without its identity wrapper), and its key goes into the plan's `namespaces`.

The walk works on values (`build_registry_from_values`), or on the plan's type, with `GeneratedValue`s
(`generate_registry_setup`), for the generated `build_registry_and_key_plan`: its code (written in
GeneratedCode/Registry/Expressions.jl) only reads out of the plan what the type does not decide.
=#

"""
    build_registry_from_values(la) -> (registry, keyed la)

The registry of the whole tree of `la`, and `la` with every child replaced by its raw algorithm and its key recorded in
its plan's `namespaces`, worked out on the values (`register_tree!`, then `registry`). Compiled once, not per plan. Used
when the layout cannot be worked out from the plan's type (see `generate_registry_setup`).
"""
@noinline Base.@nospecializeinfer function build_registry_from_values(@nospecialize(la::LoopAlgorithm))
    builder = RegistryBuilder()
    keyed_la = register_tree!(builder, la)
    return registry(builder), keyed_la
end

"""
    generate_registry_setup(LA) -> Expr

The body of `build_registry_and_key_plan` for a `LoopAlgorithm` of type `LA` (the argument is named `la`): code that
returns `(registry, keyed la)` as `build_registry_from_values(la)` does. The same walk, run on `LA`'s types, decides the
whole registry and the keyed plan; the code returned only reads the values the types do not decide out of `la` and
puts them in place (the rest are constants, `is_known_value`). When a step needs the values (`NeedsValues`), the code returned calls
`build_registry_from_values(la)`; any other error of the walk is thrown, so a bug on the types path does not silently
move a plan to the run-time path.
"""
Base.@nospecializeinfer function generate_registry_setup(@nospecialize(LA))
    builder = RegistryBuilder()
    keyed = try
        register_tree!(builder, GeneratedValue(LA, :la))
    catch err
        err isa NeedsValues || rethrow()
        return :(build_registry_from_values(la))
    end
    return Expr(:tuple, write_registry_expr(builder), keyed.value_expr)
end

###############################################################################
# The walk
###############################################################################

"""
    register_tree!(builder, la) -> keyed la

Adds the whole tree of the `LoopAlgorithm` `la` to `builder`: its states first (`register_states!`), then its algorithms
(`register_children!`). Returns `la` with its plan keyed. `la` can be a `GeneratedValue`.
"""
Base.@nospecializeinfer function register_tree!(b::RegistryBuilder, @nospecialize(la))
    register_states!(b, la)
    plan = register_children!(b, read_plan(la), 1.0)
    return replace_fields(la, (:plan,), (plan,))
end

"""
    register_states!(builder, la)

Adds the states of `la` and of every plan nested in it (also a named one, `unwrap_named_plan`) to `builder`, each with
multiplier 1, in the order of `flat_states`. States belong to the context, not to a step, so they are registered once and first.
"""
Base.@nospecializeinfer function register_states!(b::RegistryBuilder, @nospecialize(la))
    read_type(la) <: LoopSpec || return nothing
    # Tuples are read with `getfield`, not iterated: iterating compiles once per tuple type.
    states = read_states(la)
    if read_type(states) <: Tuple
        for i in 1:count_fields(states)
            add!(b, read_field(states, i), 1.0)
        end
    elseif read_type(states) !== Nothing
        add!(b, states, 1.0)
    end
    children = read_children(la)
    for i in 1:count_fields(children)
        register_states!(b, unwrap_named_plan(require_concrete(read_field(children, i))))
    end
    return nothing
end

"""
    register_children!(builder, node, multiplier) -> keyed node

Adds the children of a plan node to `builder`, first to last (`register_child!`). Each child's multiplier (how often it
runs per root step) is `multiplier` times its own interval/repeat factor. Returns the plan with raw children and per
child its context name as a `Namespace` type (`Namespace{:Counter_1}`, or `Namespace{nothing}` for a nested plan) in its
`namespaces`. Only plans get here: `register_child!` unwraps nested wrappers.
"""
Base.@nospecializeinfer function register_children!(b::RegistryBuilder, @nospecialize(node), @nospecialize(multiplier))
    funcs = read_children(node)
    mults = read_multipliers(node)
    n = count_fields(funcs)
    raws = Vector{Any}(undef, n)
    namespaces = Vector{Any}(undef, n)
    for i in 1:n
        raws[i], namespaces[i] = register_child!(b, read_field(funcs, i), multiply_multipliers(multiplier, getfield(mults, i)))
    end
    return replace_fields(node, (:funcs, :namespaces), (build_tuple(raws, node), build_tuple(namespaces, node)))
end

"""
    register_child!(builder, child, multiplier) -> (raw child, namespace)

Adds one child to `builder`. Returns the child as its plan stores it afterwards, and its context name as a
`Namespace`: a call (`Callable`) has no identity and is not registered (its `fixed_namespace`); a nested plan (also
one wrapped in a `LoopAlgorithm` or `FinalizedAlgorithm`, or given a name, which is dropped) introduces no namespace and
has its children added instead (`_unwrap_nested_plan`); any other algorithm or state is keyed by the registry (`add!`)
and stored raw, without its identity wrapper.
"""
Base.@nospecializeinfer function register_child!(b::RegistryBuilder, @nospecialize(child), @nospecialize(multiplier))
    T = read_type(require_concrete(child))
    if T <: Callable
        # On types: every call's `fixed_namespace`.
        name = child isa GeneratedValue ? _CALLS_NAMESPACE : fixed_namespace(child)
        return child, quote_constant(Core.apply_type(Namespace, name)(), child)
    end
    if T <: LoopSpec
        # A nested `FinalizedAlgorithm` has its final step dropped with a warning: only on the values.
        T <: FinalizedAlgorithm && child isa GeneratedValue && throw(NeedsValues())
        inner = T <: LoopAlgorithm ? read_plan(child) : T <: FinalizedAlgorithm ? _unwrap_nested_plan(child) : child
        return register_children!(b, inner, multiplier), quote_constant(Namespace{nothing}(), child)
    end
    # A named nested plan. Construction rejects `:name => plan`, but `IdentifiableAlgo(plan, :name)` and
    # `insert(la, i, :name => plan)` get here; the name is dropped and the plan is added as an unnamed one.
    # TODO (TODO.md, "named plans as context slices"): record the name here as `:name => (child SCKeys...)`.
    if T <: AbstractIdentifiableAlgo{<:LoopSpec}
        return register_child!(b, unwrap_named_plan(child), multiplier)
    end
    keyed = add!(b, child, multiplier)
    raw = child isa GeneratedValue ? read_field(keyed, :func) : getalgo(keyed)
    return raw, quote_constant(Core.apply_type(Namespace, key_of(keyed))(), child)
end

"""
    unwrap_named_plan(child) -> plan or child

Returns the plan inside a named nested plan (an `AbstractIdentifiableAlgo` of a plan); any other child unchanged. On
types only an `IdentifiableAlgo` is read (its `func` field); another handle type throws `NeedsValues`.
"""
Base.@nospecializeinfer function unwrap_named_plan(@nospecialize(child))
    T = read_type(child)
    T <: AbstractIdentifiableAlgo{<:LoopSpec} || return child
    child isa GeneratedValue || return getalgo(child)
    T <: IdentifiableAlgo || throw(NeedsValues())
    return read_field(child, :func)
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
From a value or from a `GeneratedValue`. On types, a `LoopAlgorithm` wrapper or a plan is read as the plan interface
(LoopAlgorithms/Interface.jl) describes it: children in `funcs`, states in `states`, and `multipliers` of the plan's
type; anything else throws `NeedsValues`.
=#

"""The plan inside the `LoopAlgorithm` `la` (`getplan`)."""
read_plan(@nospecialize(la)) = la isa GeneratedValue ? require_concrete(read_field(la, :plan)) : getplan(la)

"""The children of `la` (`getalgos`)."""
Base.@nospecializeinfer function read_children(@nospecialize(la))
    la isa GeneratedValue || return getalgos(la)
    la.valuetype <: LoopAlgorithm && return read_children(read_plan(la))
    la.valuetype <: AbstractPlan || throw(NeedsValues())
    return require_concrete(read_field(la, :funcs))
end

"""The states of `la` (`getstates`)."""
Base.@nospecializeinfer function read_states(@nospecialize(la))
    la isa GeneratedValue || return getstates(la)
    la.valuetype <: LoopAlgorithm && return read_states(read_plan(la))
    la.valuetype <: AbstractPlan || throw(NeedsValues())
    return require_concrete(read_field(la, :states))
end

"""
How often each child of `la` runs per run of `la` (`multipliers`), a tuple of multipliers: numbers, or for a
`GeneratedValue` the expression of one that only the plan's value decides (a routine child's repeat count).
"""
Base.@nospecializeinfer function read_multipliers(@nospecialize(la))
    la isa GeneratedValue || return multipliers(la)
    T = la.valuetype
    T <: AbstractPlan || throw(NeedsValues())
    # A `Routine`'s lifetimes or a composite's intervals are read from the schedule field's type, not with
    # `multipliers(T)`, which compiles once per plan type. Any other plan type answers `multipliers(T)`
    # (LoopAlgorithms/Interface.jl).
    T <: Union{Routine, CompositeAlgorithm} || return multipliers(T)
    schedule = read_field(la, 2)
    ms = Vector{Any}(undef, count_fields(schedule))
    for i in eachindex(ms)
        ms[i] = T <: Routine ? read_routine_multiplier(read_field(schedule, i)) : 1 / getinterval(read_type(read_field(schedule, i)))
    end
    return Tuple(ms)
end

# A routine child's multiplier: `Inf` for a lifetime without a count, else its count, known or read at run time.
Base.@nospecializeinfer function read_routine_multiplier(@nospecialize(lifetime::GeneratedValue))
    lifetime.valuetype <: IndefiniteLifetime && return Inf
    is_known_value(lifetime) && return _routine_schedule_multiplier(known_value(lifetime))
    return Expr(:call, _routine_schedule_multiplier, lifetime.value_expr)
end
