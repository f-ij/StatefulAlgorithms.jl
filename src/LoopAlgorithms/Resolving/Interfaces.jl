#=
What a plan type (`AbstractPlan`: `Routine`, `CompositeAlgorithm`, `ThreadedCompositeAlgorithm`, or a new one) provides
while a plan is prepared.

When a `Process` or `InlineProcess` is created from a plan, the plan is prepared first (`resolve`): every algorithm gets
its name, routes and shares are connected to the algorithms they point at, and each nested block gets the names its
children can see. A plan is a nested value that cannot be changed in place, so preparation makes a new copy of each
plan node with the new values, from the innermost node outwards, through the functions below. A plan type whose shape
or constructor differs from the defaults adds its own methods here.

These run once per plan node, not per step, and are called with the plan's types treated as values: methods should not
rely on being inlined or on their argument types being known while compiling.
=#

###############################################################################
# A copy with new children and wiring
###############################################################################

"""
    rebuild_plan(plan, funcs::Tuple, wiring) -> plan copy

A copy of `plan` whose children are `funcs` and whose wiring is `wiring`; every other field is the same. A type
parameter of the plan that was the type of the old children or old wiring becomes the type of the new value (as
`setfield` does), so the copy's type follows its new contents.

Default: calls the plan type's constructor with all its fields, in field order. Correct for any plan type that stores
`funcs` and `wiring` as fields and whose constructor takes all fields in order (Julia's default constructor). A plan
type that stores its children or wiring differently, or whose constructor takes other arguments, defines its own
method.
"""
Base.@nospecializeinfer function rebuild_plan(@nospecialize(plan::AbstractPlan), @nospecialize(funcs::Tuple), @nospecialize(wiring))
    return _with_fields(plan, (:funcs, :wiring), (funcs, wiring))
end

"""
`s` with the fields `names` set to `values`, built by `s`'s type's constructor called with all fields in order; a type
parameter of `s` that was the type of a replaced field becomes the type of the new value. Used by the defaults above;
works on types as values, so it is compiled once, not once per plan type.
"""
Base.@nospecializeinfer function _with_fields(@nospecialize(s), names::Tuple{Vararg{Symbol}}, @nospecialize(values::Tuple))
    T = typeof(s)
    params = Any[T.parameters...]
    fields = Any[getfield(s, i) for i in 1:nfields(s)]
    for k in 1:length(names)
        i = Base.fieldindex(T, names[k])
        old = fieldtype(T, i)
        new = getfield(values, k)
        for j in eachindex(params)
            if params[j] == old
                params[j] = typeof(new)
                break
            end
        end
        fields[i] = new
    end
    return Core.apply_type(T.name.wrapper, params...)(fields...)
end
