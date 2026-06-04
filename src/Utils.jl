
export merge_nested_namedtuples, separate_nested_namedtuples

"""
    filter_by_type(T, args...)
    filter_by_type(T, args::Tuple)

Return a tuple containing only those arguments whose static type is a subtype of `T`.

This is intended for specialized vararg/tuple call sites where the tuple type is already
known to the compiler, so the selection can be resolved at compile time instead of by
runtime `filter`/`isa` checks.
"""
@inline filter_by_type(::Type{T}, args...) where {T} = filter_by_type(T, args)

"""
From a tuple do a type stable filter by type
"""
@inline @generated function filter_by_type(::Type{T}, args::Args) where {T, Args<:Tuple}
    kept = Any[]
    for (idx, arg_type) in enumerate(Args.parameters)
        if arg_type <: T
            push!(kept, :(getfield(args, $idx)))
        end
    end
    return Expr(:tuple, kept...)
end

"""
Remove an optional parsed argument from the args tuple. If the parsed_idx is nothing, return the original args.
"""
function remove_optional_parsed_arg(args, parsed_idx)
    isnothing(parsed_idx) ? args : args[setdiff(1:length(args), parsed_idx)]
end

"""
From a function, filter args..., i.e. return first argument that evaluates to true
    and return the rest of the args
"""
function parse_by_func(func, args...; default = nothing, error = true)
    t_idx = findfirst(x -> func(x), args)
    if isnothing(t_idx)
        if error && isnothing(default)
            error("Expected argument matching function $func not found in arguments: $args")
        else
            return default, args
        end
    else
        el = args[t_idx]
        args = remove_optional_parsed_arg(args, t_idx)
        return el, args
    end
end

"""
    merge_nested_namedtuples(base, updates)

Merge two nested `NamedTuple`s by field name, assuming at most two layers.

- Top-level names follow normal merge behavior: existing fields stay in place and new
  fields from `updates` are appended.
- If a top-level field exists on both sides and both values are `NamedTuple`s, that
  nested named tuple is merged one level deeper by field name as well.
- Otherwise the value from `updates` replaces the one in `base`.
"""
Base.@constprop :aggressive @generated function merge_nested_namedtuples(base::NT1, updates::NT2) where {NT1<:NamedTuple, NT2<:NamedTuple}
    outer_names_1 = fieldnames(NT1)
    outer_names_2 = fieldnames(NT2)
    merged_outer_names = (outer_names_1..., (name for name in outer_names_2 if name ∉ outer_names_1)...)

    function _nested_merge_expr(base_expr, update_expr, T1, T2)
        inner_names_1 = fieldnames(T1)
        inner_names_2 = fieldnames(T2)
        merged_inner_names = (inner_names_1..., (name for name in inner_names_2 if name ∉ inner_names_1)...)
        inner_fields = Any[]

        for name in merged_inner_names
            value_expr = if name in inner_names_2
                :(getproperty($update_expr, $(QuoteNode(name))))
            else
                :(getproperty($base_expr, $(QuoteNode(name))))
            end
            push!(inner_fields, Expr(:kw, name, value_expr))
        end

        return Expr(:tuple, Expr(:parameters, inner_fields...))
    end

    outer_fields = Any[]
    for name in merged_outer_names
        value_expr = if name in outer_names_1 && name in outer_names_2
            T1 = fieldtype(NT1, name)
            T2 = fieldtype(NT2, name)
            if T1 <: NamedTuple && T2 <: NamedTuple
                _nested_merge_expr(
                    :(getproperty(base, $(QuoteNode(name)))),
                    :(getproperty(updates, $(QuoteNode(name)))),
                    T1,
                    T2,
                )
            else
                :(getproperty(updates, $(QuoteNode(name))))
            end
        elseif name in outer_names_1
            :(getproperty(base, $(QuoteNode(name))))
        else
            :(getproperty(updates, $(QuoteNode(name))))
        end

        push!(outer_fields, Expr(:kw, name, value_expr))
    end

    return Expr(:tuple, Expr(:parameters, outer_fields...))
end

"""
    separate_nested_namedtuples(nt)

Split a nested `NamedTuple` into a tuple of one-entry `NamedTuple`s, preserving
top-level field order.

Example:

```julia
separate_nested_namedtuples((; a = (; x = 1), b = (; y = 2)))
# => ((; a = (; x = 1)), (; b = (; y = 2)))
```
"""
Base.@constprop :aggressive @generated function separate_nested_namedtuples(nt::NT) where {NT<:NamedTuple}
    names = fieldnames(NT)
    separated = Any[]

    for name in names
        push!(
            separated,
            Expr(:tuple, Expr(:parameters, Expr(:kw, name, :(getproperty(nt, $(QuoteNode(name))))))),
        )
    end

    return Expr(:tuple, separated...)
end

@inline filter_nt(nt::NT, keys...) where NT = @inline Base.structdiff(nt, NamedTuple{tuple(keys...)})
