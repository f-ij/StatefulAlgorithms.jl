#=
Lets one registry walk serve both the run-time setup and the generated one.

The generated `build_registry_and_key_plan` decides the whole registry from the plan's type, before any plan value
exists. The walk that decides it (`register_tree!`, `add!`) then gets `GeneratedValue`s instead of values: values the
generated function computes at run time, of which the generator knows the type and the expression that gives them.
The helpers below (`read_field`, `read_type`, `count_fields`, `build_tuple`, ...) do the same on a value and on a
`GeneratedValue`, so the walk is written once. The expressions themselves are written in
GeneratedCode/RegistryExpressions.jl.
=#

"""
    GeneratedValue(valuetype, value_expr, field_values = nothing)

A value that the generated `build_registry_and_key_plan` computes at run time, as the generator knows it: its type
`valuetype`, which the registry rules decide on, and `value_expr`, the expression in the generated function that gives
it: a `getfield` chain into the plan (`getfield(getfield(la, :plan), :funcs)`), a constant (`QuoteNode`) when the type
alone decides the value, or the expression that builds it. For a value the generated code builds (a keyed handle, a
rebuilt plan node, a registry entry), `field_values` holds the `GeneratedValue`s of its fields.
"""
struct GeneratedValue
    valuetype::Any
    value_expr::Any
    field_values::Union{Nothing, Vector{Any}}
end
GeneratedValue(@nospecialize(valuetype), @nospecialize(value_expr)) = GeneratedValue(valuetype, value_expr, nothing)

"""
    NeedsValues()

Thrown by the walk on the plan's type when a step needs the values themselves (a merge, an algorithm that is not a
handle, a plan type whose children are not its fields). The registry is then set up from the values, at run time.
"""
struct NeedsValues <: Exception end

"""The type of `x`: of the value, or of the value a `GeneratedValue` stands for."""
read_type(@nospecialize(x)) = x isa GeneratedValue ? x.valuetype : typeof(x)

"""
    read_field(x, f) -> field

Field `f` (a name or an index) of `x`: the value's field, or for a `GeneratedValue` the `GeneratedValue` of that field
(its declared type, read with `getfield` from `x`; a constant when its type is a singleton or `x` is a constant). A
field whose value decides something must have a concrete declared type: see `require_concrete`.
"""
Base.@nospecializeinfer function read_field(@nospecialize(x), f::Union{Symbol, Int})
    x isa GeneratedValue || return getfield(x, f)
    if !isnothing(x.field_values)
        return x.field_values[f isa Int ? f : Base.fieldindex(x.valuetype, f)]
    end
    T = fieldtype(x.valuetype, f)
    Base.issingletontype(T) && return GeneratedValue(T, QuoteNode(T.instance))
    is_known_value(x) && return GeneratedValue(T, QuoteNode(getfield(known_value(x), f)))
    return GeneratedValue(T, Expr(:call, getfield, x.value_expr, QuoteNode(f)))
end

"""Whether the generator already knows the value of `x`, so the generated function holds it as a constant."""
is_known_value(x::GeneratedValue) = x.value_expr isa QuoteNode

"""The value of `x`, known to the generator (`is_known_value`)."""
known_value(x::GeneratedValue) = (x.value_expr::QuoteNode).value

"""The number of fields of `x` (of the value a `GeneratedValue` stands for)."""
count_fields(@nospecialize(x)) = x isa GeneratedValue ? fieldcount(x.valuetype) : nfields(x)

"""
    require_concrete(x) -> x

Returns `x`; throws `NeedsValues` for a `GeneratedValue` whose type is not concrete (its value, not its type, decides).
"""
require_concrete(@nospecialize(x)) = (x isa GeneratedValue && !isconcretetype(x.valuetype) && throw(NeedsValues()); x)

"""
    build_tuple(xs, like) -> tuple

The tuple of `xs`: a tuple of the values, or, when `like` is a `GeneratedValue`, the `GeneratedValue` of the tuple of
the `GeneratedValue`s `xs` (`build_from_parts`).
"""
Base.@nospecializeinfer function build_tuple(xs::Vector{Any}, @nospecialize(like))
    like isa GeneratedValue || return Tuple(xs)
    return build_from_parts(Tuple{Any[read_type(x) for x in xs]...}, xs)
end

"""The constant `v`; a `GeneratedValue` of it when `like` is one."""
quote_constant(@nospecialize(v), @nospecialize(like)) = like isa GeneratedValue ? GeneratedValue(typeof(v), QuoteNode(v)) : v
