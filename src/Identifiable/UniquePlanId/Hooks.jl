"""
    rebuild_with_fields(x, fields::Vector{Any}) -> x's kind of value with `fields`

`x` built again with new field values, as `replace_unique_ids` does to each struct on a path to a replaced id. Default:
a tuple or named tuple of `fields`; a struct of `x`'s type with each type parameter that a field is declared as set to
that field's new type, the others kept. A type with a parameter worked out from a field in another way adds a method.
Extended by: `IdentifiableAlgo` (its id from its matcher, Identifiable/HookExtensions.jl); `Route`, `Share`,
`Redirect` (their endpoint matchers, RoutingInterface/HookExtensions.jl).
"""
Base.@nospecializeinfer function rebuild_with_fields(@nospecialize(x), fields::Vector{Any})
    x isa Tuple && return Core._apply_iterate(iterate, tuple, fields)
    T = typeof(x)
    x isa NamedTuple && return NamedTuple{T.parameters[1]}(Core._apply_iterate(iterate, tuple, fields))
    return new_instance(Core.apply_type(T.name.wrapper, _params_from_fields(T, fields)...), fields...)
end

# The type parameters of `T` with each one a field is declared as set to that field's new type.
Base.@nospecializeinfer function _params_from_fields(@nospecialize(T::DataType), fields::Vector{Any})
    params = Any[T.parameters...]
    for i in eachindex(fields)
        j = _field_parameter_index(T, i)
        isnothing(j) || (params[j] = typeof(fields[i]))
    end
    return params
end
