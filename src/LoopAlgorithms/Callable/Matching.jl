"""
Endpoint of a route that belongs to one plan child (a `WithWiring` wire): matched to its
child when the plan is built, and pointed at that child's namespace at resolve.
"""
struct OwnerMatcher <: AbstractMatcher{nothing} end

# Calls have no identity: they are not registered and all share the `_captured_returns` namespace. Routes
# into a call are attached to that call (by `WithWiring`, or by the DSL); a route that names a
# call as an endpoint resolves to `_captured_returns`.
@inline fixed_namespace(::Callable) = :_captured_returns
@inline match_by(::Callable) = OwnerMatcher()
@inline match_by(::Type{<:Callable}) = OwnerMatcher
match(child::Callable, owner::Callable) = child === owner
match(child, owner::Callable) = false
match(child::Callable, owner) = false

"""Target placeholder of a wire inside `WithWiring`: the wrapped child."""
struct ThisChild end
@inline match_by(::ThisChild) = OwnerMatcher()
