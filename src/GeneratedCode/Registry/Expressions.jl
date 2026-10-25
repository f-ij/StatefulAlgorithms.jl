#=
Writes the body of the generated `build_registry_and_key_plan` (Setup.jl): the expressions that build a
plan's registry and keyed plan, from what the walk on the plan's type decided (`GeneratedValue`s,
Registry/GeneratedValues.jl).

What the type alone decides is a constant in that body, so it is neither read nor built per call: algorithms and
handles whose type is a singleton, tuples of those, and each entry's multipliers and lookup table (shared by all plans
of the type; a registry's are only read, adding to one copies them, `RegistryBuilder(registry)`). Structs are made by
the generated code (`write_struct_expr`).
=#

"""
    build_from_parts(T, parts) -> GeneratedValue

The `GeneratedValue` of a value of type `T` (a tuple or a struct) made from `parts` (the `GeneratedValue`s of its
elements or fields, in order, kept as its `field_values`). A tuple of constants is built now and is a constant itself;
anything else is made by the generated code (`write_struct_expr`).
"""
Base.@nospecializeinfer function build_from_parts(@nospecialize(T), parts::Vector{Any})
    exprs = Any[p.value_expr for p in parts]
    T <: Tuple || return GeneratedValue(T, write_struct_expr(T, exprs), parts)
    all(is_known_value, parts) && return GeneratedValue(T, QuoteNode(Tuple(Any[known_value(p) for p in parts])), parts)
    return GeneratedValue(T, Expr(:tuple, exprs...), parts)
end

"""
    write_struct_expr(T, field_exprs) -> expression

The expression that makes a `T` from the expressions of its fields: `Expr(:new, T, fields...)` for a type of this
package, whose constructor `T(fields...)` is the default one (the tests check that the generated and the run-time
setup agree); a call of its constructor for a type of another package (a plan type). With `new` there is no
constructor call to infer and inline, and none that Julia runs (compiling it on its own) when the fields are constants.
"""
Base.@nospecializeinfer write_struct_expr(@nospecialize(T::DataType), field_exprs::Vector{Any}) =
    parentmodule(T) === (@__MODULE__) ? Expr(:new, T, field_exprs...) : Expr(:call, T, field_exprs...)

"""
    write_registry_expr(builder) -> expression

The expression that builds the registry `builder` holds (filled by the walk on the plan's type), the same one
`registry(builder)` builds from values: the registry's type written out, its algorithms read from the plan or
constants (`build_known_entry`).
"""
Base.@nospecializeinfer function write_registry_expr(b::RegistryBuilder)
    entries = Any[build_known_entry(entry) for entry in b.entries]
    all_entries = build_tuple(entries, GeneratedValue(Nothing, nothing))
    return build_from_parts(NameSpaceRegistry{all_entries.valuetype}, Any[all_entries]).value_expr
end

"""The `GeneratedValue` of the registry entry that `entry` (of a builder filled by the walk on types) holds."""
Base.@nospecializeinfer function build_known_entry(entry::TypeEntryBuilder)
    algos = build_tuple(entry.algos, GeneratedValue(Nothing, nothing))
    multipliers = GeneratedValue(Vector{Float64}, QuoteNode(copy(entry.multipliers)))
    lookup = GeneratedValue(Dict{LookupKey,Int}, write_lookup_table_expr(entry.lookup))
    return build_from_parts(RegistryTypeEntry{entry.type, algos.valuetype}, Any[algos, multipliers, lookup])
end

"""
    write_lookup_table_expr(lookup) -> expression

The expression that gives an entry's lookup table `lookup` (of a builder filled by the walk on types): the table of
its fixed keys as a constant, or, when some keys are only known at run time (normalized handles), a copy of it with
those keys added.
"""
Base.@nospecializeinfer function write_lookup_table_expr(lookup::BuilderLookup)
    fixed_keys, fixed_idxs = LookupKey[], Int[]
    runtime = Any[]
    for (k, i) in lookup
        if k isa RuntimeLookupKey
            push!(runtime, Expr(:call, setindex!, :d, i, Expr(:call, dynamic_lookup_key, k.handle_expr)))
        else
            push!(fixed_keys, k::LookupKey); push!(fixed_idxs, i)
        end
    end
    fixed = QuoteNode(lookup_table(Tuple(fixed_keys), Tuple(fixed_idxs)))
    isempty(runtime) && return fixed
    return Expr(:let, Expr(:(=), :d, Expr(:call, copy, fixed)), Expr(:block, runtime..., :d))
end

"""A new lookup table with `keys[i] => idxs[i]`."""
Base.@nospecializeinfer function lookup_table(@nospecialize(keys::Tuple), @nospecialize(idxs::Tuple))
    d = Dict{LookupKey,Int}()
    sizehint!(d, length(keys))
    for i in 1:length(keys)
        d[getfield(keys, i)::LookupKey] = getfield(idxs, i)::Int
    end
    return d
end
