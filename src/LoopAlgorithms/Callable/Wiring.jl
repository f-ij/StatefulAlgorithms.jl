"""
    WithWiring(child, wires...)

Wiring that belongs to one plan child, attached by position: the target of each wire is
`child` itself, so it needs no identity. Works for any child (an algorithm or an
[`Callable`](@ref)). Wires are made with [`From`](@ref).

    CompositeAlgorithm(Sensor, WithWiring(Callable(total_energy, (:spins,), :energy), From(Sensor, :state => :spins)), ...)
"""
struct WithWiring{C}
    child::C
    # Untyped on purpose: the wires only travel to the plan constructor, which builds the typed
    # wiring. Keeping their types (which include their source objects) out of `WithWiring`
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
# A `Var` already stores its reference as a route stores an endpoint (an SCKey or a matcher type).
_var_route(::Var{Ref, name, transform}, alias::Symbol) where {Ref, name, transform} =
    Route{Ref, OwnerMatcher, transform, nothing, (name,), (alias,), Nothing, ThisChild}(nothing, ThisChild())
