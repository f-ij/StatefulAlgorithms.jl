#=
Interface of `AbstractPlan` (`Routine`, `CompositeAlgorithm`, `ThreadedCompositeAlgorithm`, or a new plan type): what
every plan provides. The type itself is in AbstractTypeDefs.jl.

A plan stores its children in `funcs`, its states in `states`, its route/share wiring in `wiring` (a `PlanWiring`), its
options in `options`, and, once resolved, its children's context names in `namespaces` (one `Namespace` type per
child). The getters below read those fields; a plan type that stores them differently defines its own methods.

Each plan type defines `multipliers(plan)` and `multipliers(typeof(plan))`: how often each child runs per run of the
plan, a tuple of numbers (from its intervals or repeats). The type method is used when the registry is set up from the
plan's type (Resolving/Registering.jl).
=#

###############################################################################
# Getters
###############################################################################

"""Return the children of `plan`."""
@inline getalgos(plan::P) where {P<:AbstractPlan} = getfield(plan, :funcs)
"""Return the states of `plan` (the states declared on it, not those of nested plans)."""
@inline getstates(plan::P) where {P<:AbstractPlan} = getfield(plan, :states)
"""Return the route/share wiring of `plan`, a `PlanWiring`."""
@inline getwiring(plan::P) where {P<:AbstractPlan} = getfield(plan, :wiring)
"""Return the options of `plan`."""
@inline getoptions(plan::P) where {P<:AbstractPlan} = getfield(plan, :options)
"""Return child `idx` of `plan`."""
@inline getalgo(plan::P, idx::I) where {P<:AbstractPlan, I} = getalgos(plan)[idx]
"""Return the children of `plan`, as `getalgos`."""
@inline subalgorithms(plan::P) where {P<:AbstractPlan} = getalgos(plan)

###############################################################################
# A copy with new children and wiring, while a plan is resolved
###############################################################################
#=
When a `Process` or `InlineProcess` is created from a plan, the plan is resolved first (`resolve`, Resolving/): every
algorithm gets its name, routes and shares are connected to the algorithms they point at, and each nested block gets
the names its children can see. A plan is a nested value that cannot be changed in place, so resolving makes a new
copy of each plan node with the new values, from the innermost node outwards, through `rebuild_plan`. A plan type whose
shape or constructor differs from the default defines its own method.

This runs once per plan node, not per step, and is called with the plan's types treated as values: a method should not
rely on being inlined or on its argument types being known while compiling.
=#

"""
    rebuild_plan(plan, funcs::Tuple, wiring) -> plan copy

A copy of `plan` whose children are `funcs` and whose wiring is `wiring`; every other field is the same. The type
parameter that the `funcs` or `wiring` field is declared as becomes the type of the new value, so the copy's type
follows its new contents.

Default: calls the plan type's constructor with all its fields, in field order. Correct for any plan type that stores
`funcs` and `wiring` as fields and whose constructor takes all fields in order (Julia's default constructor). A plan
type that stores its children or wiring differently, or whose constructor takes other arguments, defines its own
method.
"""
Base.@nospecializeinfer function rebuild_plan(@nospecialize(plan::AbstractPlan), @nospecialize(funcs::Tuple), @nospecialize(wiring))
    return replace_fields(plan, (:funcs, :wiring), (funcs, wiring))
end

"""
    rebuild_plan_typed(plan, funcs::Tuple, wiring) -> plan copy

The inferred `rebuild_plan`, used by the typed resolve (Resolving/Typed.jl): the same copy, built with `setfield`, so a
caller that knows the plan type gets the copy's type at compile time. A plan type that defines its own `rebuild_plan`
defines this one too.
"""
@inline rebuild_plan_typed(plan::P, funcs::F, wiring::W) where {P<:AbstractPlan, F<:Tuple, W} =
    setfield(setfield(plan, :funcs, funcs), :wiring, wiring)

"""
Return a copy of `plan` whose children are `funcs`; every other field is the same (`setfield`). Inferred; used where
only the children change (step 1 of `resolve`, the DSL).
"""
@inline rebuild_loopalgorithm_funcs(plan::P, funcs::F) where {P<:AbstractPlan, F} = setfield(plan, :funcs, funcs)

"""
    replace_fields(s, names, values) -> copy of s

`s` with the fields `names` set to `values`, built by `s`'s type's constructor called with all fields in order; the
type parameter that a replaced field is declared as (`_field_parameter_index`) becomes the type of the new value. Used
by the defaults above and the registry walk; works on types as values, so it is compiled once, not once per plan type.

`s` can be a `GeneratedValue` (with `values` `GeneratedValue`s): the result is then a `GeneratedValue` of the new type, built
from `s`'s other fields and the new values (`build_from_parts`).
"""
Base.@nospecializeinfer function replace_fields(@nospecialize(s), names::Tuple{Vararg{Symbol}}, @nospecialize(values::Tuple))
    T = read_type(s)
    params = Any[T.parameters...]
    fields = Any[read_field(s, i) for i in 1:count_fields(s)]
    for k in 1:length(names)
        i = Base.fieldindex(T, names[k])
        new = getfield(values, k)
        j = _field_parameter_index(T, i)
        isnothing(j) || (params[j] = read_type(new))
        fields[i] = new
    end
    NT = Core.apply_type(T.name.wrapper, params...)
    s isa GeneratedValue || return NT(fields...)
    return build_from_parts(NT, fields)
end
