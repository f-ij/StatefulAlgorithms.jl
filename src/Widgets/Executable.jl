export Executable, Literal, Splat, WithWiring, From

"""
    Literal(x)

A literal argument value for an [`Executable`](@ref). Only needed for a `Symbol` value,
which would otherwise be read as a plan name: `Executable(f, (Literal(:fast),), ...)`.
"""
struct Literal{T}
    value::T
end

"""
    Splat(:name)

`name...` in an [`Executable`](@ref) signature. Among the arguments it spreads the plan value
`name` into several arguments (`f(xs...)`, `f(; opts...)`); among the returns it collects the
remaining returned values into `name` (`(a, b...) = f()`).
"""
struct Splat{name} end
Splat(name::Symbol) = Splat{name}()
splatname(::Splat{name}) where {name} = name

"""
    Executable(f, args, kwargs, returns)
    Executable(f, args, returns)

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
call (the shared `_runtime` bucket), a runtime input, or whatever [`WithWiring`](@ref) wires to
that name. A return name that is a visible local, or wired, is written there; any other return
is a step value in the shared `_runtime` bucket. Executables have no state, no identity and no
registry entry; the signature is type data, so one function with one signature compiles once.
"""
struct Executable{F, Args, Kwargs, Returns, V} <: ProcessAlgorithm
    f::F
    values::V   # literal argument values, indexed by `ValueRef`
end

function Executable(f::F, args::Tuple, kwargs, returns) where {F}
    literals = Any[]
    literal(x) = (push!(literals, x isa Literal ? x.value : x); ValueRef{length(literals), typeof(literals[end])}())
    arg(x) = x isa Symbol || x isa Splat ? x : literal(x)
    encoded_args = map(arg, args)
    kwarg_pieces = kwargs isa NamedTuple ? (kwargs,) : Tuple(kwargs)
    encoded_kwargs = Tuple(Iterators.flatten(map(kwarg_pieces) do piece
        piece isa Splat && return (piece,)
        piece isa NamedTuple || error("Executable keywords must be named tuples or `Splat(:name)`, got $(piece)")
        return map((name, x) -> (name, arg(x)), keys(piece), values(piece))
    end))
    encoded_returns = _encode_returns(returns)
    literal_values = Tuple(literals)
    return Executable{F, encoded_args, encoded_kwargs, encoded_returns, typeof(literal_values)}(f, literal_values)
end
Executable(f, args::Tuple, returns) = Executable(f, args, (;), returns)

# Returns are encoded as the type `Tuple{Val{kind}, Val{names}, Tuple{types...}}` (a type, so it can
# hold the return types); `Any` means unchecked.
_returns_type(kind, names, types) = Tuple{Val{kind}, Val{names}, types}
_returns_parts(::Type{Tuple{Val{kind}, Val{names}, types}}) where {kind, names, types} = (kind, names, types)
_return_name(x::Symbol) = (x, Any)
_return_name(x::Splat) = (x, Any)
_return_name(x::Pair{<:Union{Symbol, Splat}, <:Type}) = (x.first, x.second)
_return_name(x) = error("Executable return names are `Symbol`s, `Splat(:name)`, or `name => Type`; got $(x)")
function _encode_returns(returns)
    returns === () && return _returns_type(:none, (), Tuple{})
    if returns isa NamedTuple
        named = map(_return_name, values(returns))
        return _returns_type(:properties, Tuple(zip(keys(returns), first.(named))), Tuple{last.(named)...})
    end
    if returns isa Tuple
        named = map(_return_name, returns)
        count(n -> first(n) isa Splat, named) <= 1 || error("At most one `Splat` in Executable returns, got $(returns)")
        return _returns_type(:unpack, first.(named), Tuple{last.(named)...})
    end
    name, T = _return_name(returns)
    name isa Splat && error("A single Executable return cannot be `Splat`; use `(Splat(:$(splatname(name))),)`")
    return _returns_type(:single, (name,), Tuple{T})
end

_input_names(item::Symbol) = (item,)
_input_names(item::Splat) = (splatname(item),)
_input_names(item::Tuple) = _input_names(last(item))   # keyword (name, input)
_input_names(item) = ()                                # literal

_input_var(name::Symbol) = Symbol("in#", name)
_output_var(name::Symbol) = Symbol("out#", name)
_arg_expr(item::Symbol) = _input_var(item)
_arg_expr(item::Splat) = Expr(:..., _input_var(splatname(item)))
_arg_expr(::ValueRef{index}) where {index} = :(getfield(getfield(ex, :values), $index))
_kwarg_expr(item::Splat) = Expr(:..., _input_var(splatname(item)))
_kwarg_expr(item::Tuple) = Expr(:kw, first(item), _arg_expr(last(item)))

"""Read the input names from `view`, call the function, and return the outputs by plan name."""
@inline @generated function step!(ex::Executable{F, Args, Kwargs, Returns}, view) where {F, Args, Kwargs, Returns}
    input_names = unique(Symbol[n for item in (Args..., Kwargs...) for n in _input_names(item)])
    reads = [:($(_input_var(n)) = @inline getproperty(view, $(QuoteNode(n)))) for n in input_names]
    call = Expr(:call, :(getfield(ex, :f)), Expr(:parameters, map(_kwarg_expr, Kwargs)...), map(_arg_expr, Args)...)
    call = :(@inline $call)

    kind, names, types = _returns_parts(Returns)
    kind === :none && return quote
        $(reads...)
        $call
        return (;)
    end
    plan_names = kind === :properties ? map(last, names) : map(n -> n isa Splat ? splatname(n) : n, names)
    assign = if kind === :single
        :($(_output_var(only(plan_names))) = $call)
    elseif kind === :unpack
        lhs = Expr(:tuple, (n isa Splat ? Expr(:..., _output_var(splatname(n))) : _output_var(n) for n in names)...)
        :($lhs = $call)
    else   # :properties
        quote
            value = $call
            $((:($(_output_var(last(p))) = getproperty(value, $(QuoteNode(first(p))))) for p in names)...)
        end
    end
    checks = [:($(_output_var(plan_names[i]))::$(fieldtype(types, i))) for i in 1:length(plan_names) if fieldtype(types, i) !== Any]
    result = Expr(:tuple, Expr(:parameters, (Expr(:kw, n, _output_var(n)) for n in plan_names)...))
    return quote
        $(reads...)
        $assign
        $(checks...)
        return $result
    end
end

"""The plan names an `Executable` (type) reads, or every name read by the `Executable`s in `funcs`."""
executable_input_names(::Type{<:Executable{F, Args, Kwargs}}) where {F, Args, Kwargs} =
    Tuple(unique(Symbol[n for item in (Args..., Kwargs...) for n in _input_names(item)]))
executable_input_names(::Type) = ()
executable_reads(funcs::Tuple) = Tuple(unique(Symbol[n for f in funcs for n in executable_input_names(typeof(f))]))

@inline init(::Executable, context) = (;)
@inline cleanup(::Executable, context) = (;)

"""Step an `Executable` child: view the context from the shared `_runtime` namespace, call, merge the returns."""
@inline function _step!(ex::EX, context::C, runtimecontext::RC, wiring::W, namespace::Namespace, process::P, lifetime::LT) where {EX<:Executable, C<:AbstractContext, RC<:ProcessContext, W<:PlanWiringView, P<:AbstractProcess, LT<:Lifetime}
    contextview = @inline view(
        context,
        runtimecontext,
        ex,
        Namespace{:_runtime}();
        sharedcontexts = (@inline shares(wiring)),
        sharedvars = (@inline view_routes(wiring, Namespace{:_runtime}())),
    )
    retval = @inline step!(ex, contextview)
    return @inline merge_funcwrapper_return(contextview, context, runtimecontext, retval, return_demand(wiring, Namespace{:_runtime}()))
end
@inline _step!(ex::EX, context::C, runtimecontext::RC, wiring::W, process::P, lifetime::LT) where {EX<:Executable, C<:AbstractContext, RC<:ProcessContext, W<:PlanWiringView, P<:AbstractProcess, LT<:Lifetime} =
    @inline _step!(ex, context, runtimecontext, wiring, Namespace{:_runtime}(), process, lifetime)

# Routes into an executable are attached to that call (by `WithWiring`, or by the DSL); a route
# that names an executable as an endpoint resolves to the shared `_runtime` namespace.
@inline match_by(::Executable) = OwnerMatcher()
@inline match_by(::Type{<:Executable}) = OwnerMatcher
match(child::Executable, owner::Executable) = child === owner
match(child, owner::Executable) = false
match(child::Executable, owner) = false

"""The `Executable` a DSL `FuncWrapper` describes."""
function Executable(fw::FuncWrapper{F, InputSymbols, OutputSymbols, Kwargs}) where {F, InputSymbols, OutputSymbols, Kwargs}
    values = getfield(fw, :values)
    input(x) = x isa ValueRef ? Literal(values[_valueref_index(x)]) : x
    returns = length(OutputSymbols) == 0 ? () : length(OutputSymbols) == 1 ? only(OutputSymbols) : OutputSymbols
    return Executable(getfield(fw, :func), map(input, InputSymbols), Kwargs, returns)
end

function Base.show(io::IO, ex::Executable{F, Args, Kwargs, Returns}) where {F, Args, Kwargs, Returns}
    shown(item::Symbol) = string(item)
    shown(item::Splat) = string(splatname(item), "...")
    shown(item::ValueRef) = repr(getfield(ex, :values)[_valueref_index(item)])
    shown(item::Tuple) = string(first(item), " = ", shown(last(item)))
    kind, names, types = _returns_parts(Returns)
    returned = kind === :none ? "nothing" : kind === :properties ? "(; " * join((string(first(p), " → ", last(p)) for p in names), ", ") * ")" :
        join((n isa Splat ? string(splatname(n), "...") : string(n) for n in names), ", ")
    args = join(map(shown, Args), ", ") * (isempty(Kwargs) ? "" : "; " * join(map(shown, Kwargs), ", "))
    print(io, "Executable(", returned, " = ", getfield(ex, :f), "(", args, "))")
end

"""
    WithWiring(child, wires...)

Wiring that belongs to one plan child, attached by position: the target of each wire is
`child` itself, so it needs no identity. Works for any child (an algorithm or an
[`Executable`](@ref)). Wires are made with [`From`](@ref).

    CompositeAlgorithm(Sensor, WithWiring(Executable(total_energy, (:spins,), :energy), From(Sensor, :state => :spins)), ...)
"""
struct WithWiring{C, W<:Tuple}
    child::C
    wires::W
end
WithWiring(child, wires::Route...) = WithWiring(child, wires)

"""Target placeholder of a wire inside `WithWiring`: the wrapped child."""
struct ThisChild end
@inline match_by(::ThisChild) = OwnerMatcher()

"""
    From(source, :name => :alias, ...; transform = nothing)

A wire for [`WithWiring`](@ref): read `source.name` as `alias` in the wrapped child (renaming
optional, `:name` alone keeps the name). `source` is an algorithm (or its key), `:_runtime`
for a step value, or `:_local` for a declared local.
"""
From(source, mappings...; transform = nothing, reverse_transform = nothing) =
    Route(source => ThisChild(), mappings...; transform, reverse_transform)
