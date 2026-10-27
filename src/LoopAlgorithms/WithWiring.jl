#=
Wiring attached to one plan child by position (`WithWiring`, wires made with `From`). Works for any child: an
algorithm, a plan, or a `Callable`.
=#
export WithWiring, From

"""
Endpoint of a route that belongs to one plan child (a `WithWiring` wire): matched to its
child when the plan is built, and pointed at that child's namespace at resolve.
"""
struct OwnerMatcher <: AbstractMatcher{nothing} end

"""Target placeholder of a wire inside `WithWiring`: the wrapped child."""
struct ThisChild end
@inline match_by(::ThisChild) = OwnerMatcher()

"""
    WithWiring(child, wires...)

Wiring that belongs to one plan child, attached by position: the target namespace of each wire is
`child`'s, so it needs no identity. Works for any child (an algorithm or an
[`Callable`](@ref)). Wires are made with [`From`](@ref).

    CompositeAlgorithm(Sensor, WithWiring(Callable(total_energy, (:spins,), :energy), From(Var(Sensor, :state) => :spins)), ...)
"""
struct WithWiring{C}
    child::C
    # Untyped on purpose: the wires only travel to the plan constructor, which builds the typed
    # wiring. Keeping their types (which include their source-namespace refs) out of `WithWiring`
    # keeps the type of a plan's child list the same when an identical plan is built again.
    wires::Tuple
end
WithWiring(child, wires::Route...) = WithWiring(child, wires)
@inline fixed_namespace(w::WithWiring) = fixed_namespace(getfield(w, :child))

"""
    From(Var(subcontext_ref, :name; transform) => :alias)

A wire for [`WithWiring`](@ref): the wrapped child reads the variable `name` of the referenced
subcontext (an algorithm, its type or key, `:_captured_returns` for a captured return, or `:_declared_locals` for a
declared local), optionally transformed, as `alias`.
"""
From(wire::Pair{<:Var, Symbol}) = _var_route(first(wire), last(wire))
# The route's source endpoint from the `Var`'s matcher: a context key as itself; any other matcher as its type, with
# the matcher as the object when it carries data (a `Unique` handle's `UniquePlanId`), else `nothing`.
_var_route(var::Var{KeyMatcher{key}, name, transform}, alias::Symbol) where {key, name, transform} =
    Route{key, OwnerMatcher, transform, nothing, (name,), (alias,), Nothing, ThisChild}(nothing, ThisChild())
function _var_route(var::Var{M, name, transform}, alias::Symbol) where {M, name, transform}
    matcher = getfield(var, :matcher)
    object = carries_data(matcher) ? matcher : nothing
    return Route{M, OwnerMatcher, transform, nothing, (name,), (alias,), typeof(object), ThisChild}(object, ThisChild())
end
