#=
Interface of `ContextBundle`: what every bundle type defines. There are no defaults for these except the two below,
which every bundle gets from its `persistent` field. Each bundle type's methods are in its own file (LoopContext.jl,
InitContext.jl).

- a field `persistent`, its persistent context (read by `getpersistent`, and through it `getregistry`);
- `persistent_type(::Type{<:Bundle})`: the type of that persistent context;
- `withpersistent(bundle, persistent_context)`: a copy with the persistent context swapped;
- `rebundle(bundle, persistent_context, runtime_patch)`: the bundle a step continues with after one algorithm's
  return has been written back.

The questions code asks a bundle whose answer has a default are hooks: Hooks.jl.
=#

"""Returns the bundle's persistent context."""
@inline getpersistent(bundle::B) where {B<:ContextBundle} = getfield(bundle, :persistent)
@inline getregistry(bundle::B) where {B<:ContextBundle} = @inline getregistry(getpersistent(bundle))

"""Returns the type of a bundle type's persistent context."""
function persistent_type end

"""Copies a bundle with its persistent context swapped. The copy stays in the same scope."""
function withpersistent end

"""
    rebundle(bundle, persistent_context, runtime_patch)

Builds the bundle a step continues with, after one algorithm's return has been written back. The state it wrote is
already in `persistent_context`, which replaces the old one; the runtime values it wrote (declared locals, returns) are
in `runtime_patch` and are written into the runtime context.

`runtime_patch` is grouped by runtime context partition: `(; _declared_locals = (; x = 1.0), _captured_returns = (; y = 2))`.
During init there is no runtime context, so the patch is always empty there.
"""
function rebundle end
