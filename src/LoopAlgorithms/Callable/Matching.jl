# Calls have no identity: they are not registered and all share the `_captured_returns` namespace. Routes
# into a call are attached to that call (by `WithWiring`, or by the DSL); a route that names a
# call as an endpoint resolves to `_captured_returns`.
@inline fixed_namespace(::Callable) = :_captured_returns
@inline match_by(::Callable) = OwnerMatcher()
@inline match_by(::Type{<:Callable}) = OwnerMatcher
match(child::Callable, owner::Callable) = child === owner
match(child, owner::Callable) = false
match(child::Callable, owner) = false
