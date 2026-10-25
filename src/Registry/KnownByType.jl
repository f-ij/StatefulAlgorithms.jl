#=
Values known only by their type.

The registry layout of a plan is worked out from the plan's type, before any plan value exists
(`build_registry_and_key_plan`). The same code that builds a registry from values (`add!`, the plan walk) then
gets `KnownByType`s instead of values: a type, and the expression that gives the value at run time (part of the
generated `build_registry_and_key_plan`'s body). The functions below
read a field, count fields, or build a tuple the same way for a value and for a `KnownByType`, so that code is
written once.

A value that the type alone decides is known while generating, and is a constant in the generated code
(`is_known_value`): a field whose type is a singleton (most algorithms and handles), and a tuple of known values
(`build_from_parts`). The generated code then neither reads nor builds it. A struct is not built while generating:
the generated code makes it (`write_struct_expr`).

The functions take their arguments as values (`@nospecialize`), so they are compiled once, not once per plan type.
=#

"""
    KnownByType(type, expr, fields = nothing)

A value known only by its type while a registry layout is worked out: its type `type`, and `expr`, the expression in
the generated code that gives the value at run time (reading it from the plan with `getfield`, building it, or a
constant, a `QuoteNode`). `fields`, when `expr` builds the
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
declared type, read with `getfield` from `x`; known when its type is a singleton or `x` is known). A field whose value
decides something must have a concrete declared type: see `require_concrete`.
"""
Base.@nospecializeinfer function read_field(@nospecialize(x), f::Union{Symbol, Int})
    x isa KnownByType || return getfield(x, f)
    if !isnothing(x.fields)
        return x.fields[f isa Int ? f : Base.fieldindex(x.type, f)]
    end
    T = fieldtype(x.type, f)
    Base.issingletontype(T) && return KnownByType(T, QuoteNode(T.instance))
    is_known_value(x) && return KnownByType(T, QuoteNode(getfield(known_value(x), f)))
    return KnownByType(T, Expr(:call, getfield, x.expr, QuoteNode(f)))
end

"""Whether the value of `x` is known while generating, so the generated code holds it as a constant."""
is_known_value(x::KnownByType) = x.expr isa QuoteNode

"""The value of `x`, known while generating (`is_known_value`)."""
known_value(x::KnownByType) = (x.expr::QuoteNode).value

"""
    build_from_parts(T, parts) -> KnownByType

A `KnownByType` of the value of type `T` (a tuple or a struct) made from `parts` (`KnownByType`s of its elements or
fields, in order), kept as its fields (`read_field`). A tuple of known values is built now, a constant in the generated
code; anything else is made by the generated code (`write_struct_expr`).
"""
Base.@nospecializeinfer function build_from_parts(@nospecialize(T), parts::Vector{Any})
    exprs = Any[p.expr for p in parts]
    T <: Tuple || return KnownByType(T, write_struct_expr(T, exprs), parts)
    all(is_known_value, parts) && return KnownByType(T, QuoteNode(Tuple(Any[known_value(p) for p in parts])), parts)
    return KnownByType(T, Expr(:tuple, exprs...), parts)
end

"""
    write_struct_expr(T, exprs) -> expression

The expression, in the generated code, that makes a `T` from the expressions of its fields `exprs`: `Expr(:new, T,
fields...)` for a type of this package, whose constructor `T(fields...)` is the default one (the tests check that the
typed and the run-time setup agree); a call of its constructor for a type of another package (a plan type). With
`new` there is no constructor call to infer and inline, and none that Julia runs (compiling it on its own) when the
fields are constants.
"""
Base.@nospecializeinfer write_struct_expr(@nospecialize(T::DataType), exprs::Vector{Any}) =
    parentmodule(T) === (@__MODULE__) ? Expr(:new, T, exprs...) : Expr(:call, T, exprs...)

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
    return build_from_parts(Tuple{Any[read_type(x) for x in xs]...}, xs)
end

"""The constant `v`; a `KnownByType` of it when `like` is one."""
quote_constant(@nospecialize(v), @nospecialize(like)) = like isa KnownByType ? KnownByType(typeof(v), QuoteNode(v)) : v
