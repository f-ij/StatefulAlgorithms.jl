"""Slot of a literal argument value in a `Callable`'s `values`."""
struct ValueRef{index, T} end
@inline _valueref_index(::ValueRef{index, T}) where {index, T} = index

"""
    Literal(x)

A literal argument value for an [`Callable`](@ref). Only needed for a `Symbol` value,
which would otherwise be read as a plan name: `Callable(f, (Literal(:fast),), ...)`.
"""
struct Literal{T}
    value::T
end

"""
    Splat(:name)

`name...` in an [`Callable`](@ref) signature. Among the arguments it spreads the plan value
`name` into several arguments (`f(xs...)`, `f(; opts...)`); among the returns it collects the
remaining returned values into `name` (`(a, b...) = f()`).
"""
struct Splat{name} end
Splat(name::Symbol) = Splat{name}()
splatname(::Splat{name}) where {name} = name

"""
    Callable(f, args, kwargs, returns)
    Callable(f, args, returns)

A callable (function, closure, callable struct) as a plan child, with its signature in terms of
plan names. Each step reads the input names from the plan, calls `f`, and writes the returns.

- `args`: positional inputs in order: a `Symbol` is a plan name, `Splat(:xs)` spreads the plan
  value `xs`, anything else (or `Literal(x)`) is a literal value.
- `kwargs`: a named tuple of keyword => input (plan name or literal), or a tuple of such named
  tuples and `Splat(:opts)` in order: `f(; j, opts..., d = k)` is
  `((; j = :j), Splat(:opts), (; d = :k))`.
- `returns`: `:x` (the whole value), `(:a, :b)` (unpack), `(:a, Splat(:b))` (`(a, b...) = ...`),
  `(; a = :x, b = :y)` (properties `a`, `b` of the value, written to `x`, `y`), or `()` (nothing).
  Any return name can be `name => T`: the value must already be a `T`, otherwise a `TypeError`.

Where the names come from is the plan's concern: a declared `Local`, the output of an earlier
call (the shared `_captured_returns` bucket), a runtime input, or whatever [`WithWiring`](@ref) wires to
that name. A return name that is a visible local, or wired, is written there; any other return
is a captured return (`_captured_returns`, shared by every call). Callables have no state, no identity and no
registry entry; the signature is type data, so one function with one signature compiles once.
"""
struct Callable{F, Args, Kwargs, Returns, V} <: ProcessAlgorithm
    f::F
    values::V   # literal argument values, indexed by `ValueRef`
end

function Callable(f::F, args::Tuple, kwargs, returns) where {F}
    literals = Any[]
    literal(x) = (push!(literals, x isa Literal ? x.value : x); ValueRef{length(literals), typeof(literals[end])}())
    arg(x) = x isa Symbol || x isa Splat ? x : literal(x)
    encoded_args = map(arg, args)
    kwarg_pieces = kwargs isa NamedTuple ? (kwargs,) : Tuple(kwargs)
    encoded_kwargs = Tuple(Iterators.flatten(map(kwarg_pieces) do piece
        piece isa Splat && return (piece,)
        piece isa NamedTuple || error("Callable keywords must be named tuples or `Splat(:name)`, got $(piece)")
        return map((name, x) -> (name, arg(x)), keys(piece), values(piece))
    end))
    encoded_returns = _encode_returns(returns)
    literal_values = Tuple(literals)
    return Callable{F, encoded_args, encoded_kwargs, encoded_returns, typeof(literal_values)}(f, literal_values)
end
Callable(f, args::Tuple, returns) = Callable(f, args, (;), returns)

# Returns are encoded as the type `Tuple{Val{kind}, Val{names}, Tuple{types...}}` (a type, so it can
# hold the return types); `Any` means unchecked.
_returns_type(kind, names, types) = Tuple{Val{kind}, Val{names}, types}
_returns_parts(::Type{Tuple{Val{kind}, Val{names}, types}}) where {kind, names, types} = (kind, names, types)
_return_name(x::Symbol) = (x, Any)
_return_name(x::Splat) = (x, Any)
_return_name(x::Pair{<:Union{Symbol, Splat}, <:Type}) = (x.first, x.second)
_return_name(x) = error("Callable return names are `Symbol`s, `Splat(:name)`, or `name => Type`; got $(x)")
function _encode_returns(returns)
    returns === () && return _returns_type(:none, (), Tuple{})
    if returns isa NamedTuple
        named = map(_return_name, values(returns))
        return _returns_type(:properties, Tuple(zip(keys(returns), first.(named))), Tuple{last.(named)...})
    end
    if returns isa Tuple
        named = map(_return_name, returns)
        count(n -> first(n) isa Splat, named) <= 1 || error("At most one `Splat` in Callable returns, got $(returns)")
        return _returns_type(:unpack, first.(named), Tuple{last.(named)...})
    end
    name, T = _return_name(returns)
    name isa Splat && error("A single Callable return cannot be `Splat`; use `(Splat(:$(splatname(name))),)`")
    return _returns_type(:single, (name,), Tuple{T})
end

_input_names(item::Symbol) = (item,)
_input_names(item::Splat) = (splatname(item),)
_input_names(item::Tuple) = _input_names(last(item))   # keyword (name, input)
_input_names(item) = ()                                # literal

"""The plan names a `Callable` (type) reads, or every name read by the `Callable`s in `funcs`."""
callable_input_names(::Type{<:Callable{F, Args, Kwargs}}) where {F, Args, Kwargs} =
    Tuple(unique(Symbol[n for item in (Args..., Kwargs...) for n in _input_names(item)]))
callable_input_names(::Type) = ()

"""The plan names a `Callable` (type) writes its returns to."""
function callable_return_names(::Type{<:Callable{F, Args, Kwargs, Returns}}) where {F, Args, Kwargs, Returns}
    kind, names, _ = _returns_parts(Returns)
    kind === :none && return ()
    return Tuple(kind === :properties ? map(last, names) : map(n -> n isa Splat ? splatname(n) : n, names))
end
callable_return_names(::Type) = ()
