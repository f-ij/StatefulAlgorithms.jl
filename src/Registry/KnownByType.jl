#=
Values known only by their type.

The registry layout of a plan is worked out from the plan's type, before any plan value exists
(`setup_registry_and_keyed_algos`). The same code that builds a registry from values (`add!`, the plan walk) then
gets `KnownByType`s instead of values: a type, and the code that gives the value at run time. The functions below
read a field, count fields, or build a tuple the same way for a value and for a `KnownByType`, so that code is
written once.

The functions take their arguments as values (`@nospecialize`), so they are compiled once, not once per plan type.
=#

"""
    KnownByType(type, expr, fields = nothing)

A value known only by its type while a registry layout is worked out: its type `type`, and `expr`, the code that gives
the value at run time (reading it from the plan with `getfield`, or building it). `fields`, when `expr` builds the
value, holds the `KnownByType`s of its fields.
"""
struct KnownByType
    type::Any
    expr::Any
    fields::Union{Nothing, Vector{Any}}
end
KnownByType(@nospecialize(type), @nospecialize(expr)) = KnownByType(type, expr, nothing)

"""
    NeedsValues()

Thrown while a registry layout is worked out from types, when a step needs the values themselves (a merge, an
algorithm that is not a handle, a plan type whose children are not its fields). The registry is then set up from the
values, at run time.
"""
struct NeedsValues <: Exception end

"""The type of `x`: of the value, or the type a `KnownByType` stands for."""
read_type(@nospecialize(x)) = x isa KnownByType ? x.type : typeof(x)

"""
    read_field(x, f) -> field

Field `f` (a name or an index) of `x`: the value's field, or for a `KnownByType` a `KnownByType` of the field (its
declared type, read with `getfield` from `x`). A field whose value decides something must have a concrete declared
type: see `require_concrete`.
"""
Base.@nospecializeinfer function read_field(@nospecialize(x), f::Union{Symbol, Int})
    x isa KnownByType || return getfield(x, f)
    if !isnothing(x.fields)
        return x.fields[f isa Int ? f : Base.fieldindex(x.type, f)]
    end
    return KnownByType(fieldtype(x.type, f), Expr(:call, getfield, x.expr, QuoteNode(f)))
end

"""The number of fields of `x` (of the type a `KnownByType` stands for)."""
count_fields(@nospecialize(x)) = x isa KnownByType ? fieldcount(x.type) : nfields(x)

"""
    require_concrete(x) -> x

Returns `x`; throws `NeedsValues` for a `KnownByType` whose type is not concrete (its value, not its type, decides).
"""
require_concrete(@nospecialize(x)) = (x isa KnownByType && !isconcretetype(x.type) && throw(NeedsValues()); x)

"""
    build_tuple(xs, like) -> tuple

The tuple of `xs`: a tuple of the values, or, when `like` is a `KnownByType`, a `KnownByType` of the tuple built from
the `KnownByType`s `xs`.
"""
Base.@nospecializeinfer function build_tuple(xs::Vector{Any}, @nospecialize(like))
    like isa KnownByType || return Tuple(xs)
    types = Any[read_type(x) for x in xs]
    return KnownByType(Tuple{types...}, Expr(:tuple, Any[x.expr for x in xs]...), xs)
end

"""The constant `v`; a `KnownByType` of it when `like` is one."""
quote_constant(@nospecialize(v), @nospecialize(like)) = like isa KnownByType ? KnownByType(typeof(v), QuoteNode(v)) : v
