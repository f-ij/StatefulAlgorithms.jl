#=
Context bundles: what the code around a step or an init works on, as one value. A bundle holds the stored context
(the persistent subcontexts) and what goes with it in that phase. Views are made from a bundle and ask it for anything
beyond the stored state, by dispatch on its type. Internal: users see `ProcessContext`s.
=#

abstract type ContextBundle end

"""
    LoopContext(stored, runtime)

What one step of a loop works on: the stored context and the runtime context (inputs, declared locals and outputs; see
ContextParts.jl). Steps take one and return one.

The loop never carries a `LoopContext` from one step to the next: it carries only the stored fields its steps write and
the runtime context, and builds the `LoopContext` again at the start of every step (see Carried/Carry.jl). Building it
costs nothing once compiled, and the fields no step writes are read where they already are instead of being copied.
"""
struct LoopContext{S<:ProcessContext, R<:ProcessContext} <: ContextBundle
    stored::S
    runtime::R
end

"""
    InitContext(stored, algo, lifetime)

What init works on: the stored context being built, plus what init may ask about the run it prepares, the algorithm and
its lifetime (`processsizehint!` sizes a buffer by the number of steps). No runtime values: init runs before there are
any.
"""
struct InitContext{S<:ProcessContext, A, LT} <: ContextBundle
    stored::S
    algo::A
    lifetime::LT
end

@inline getcontext(b::ContextBundle) = getfield(b, :stored)
@inline getregistry(b::ContextBundle) = @inline getregistry(getcontext(b))
@inline getruntimecontext(lc::LoopContext) = getfield(lc, :runtime)
@inline init_lifetime(ic::InitContext) = getfield(ic, :lifetime)

"""The bundle with another stored context."""
@inline withstored(lc::LoopContext, stored::ProcessContext) = LoopContext(stored, getruntimecontext(lc))
@inline withstored(ic::InitContext, stored::ProcessContext) = InitContext(stored, getfield(ic, :algo), getfield(ic, :lifetime))

"""The stored context type of a bundle type, and the runtime context type of a `LoopContext` type."""
stored_type(::Type{<:LoopContext{S}}) where {S} = S
stored_type(::Type{<:InitContext{S}}) where {S} = S
runtime_type(::Type{<:LoopContext{S, R}}) where {S, R} = R

"""A bundle for a stored context on its own, with no runtime values (looking at a context outside a loop)."""
@inline bundle_of(pc::ProcessContext) = LoopContext(pc, _empty_context())

# Runtime values (ContextParts.jl): a `LoopContext` has them, an `InitContext` none.
@inline _runtime_subcontext_data(lc::LoopContext, name::Val) = @inline _runtime_subcontext_data(getruntimecontext(lc), name)
@inline _runtime_subcontext_data(::InitContext, ::Val) = (;)

@inline get_part_data(lc::LoopContext, part::ContextPart) = @inline get_part_data(getruntimecontext(lc), part)
@inline get_part_data(::InitContext, ::ContextPart) = (;)

"""The data type of a runtime part in a bundle type; empty when it has no such part."""
_part_data_type(::Type{B}, part::ContextPart) where {B<:LoopContext} = _part_data_type(runtime_type(B), part)
_part_data_type(::Type{<:InitContext}, ::ContextPart) = NamedTuple{(), Tuple{}}

"""What `finalstep` gets: the loop's stored and runtime values as one `ProcessContext` (see `_visible_context`)."""
@inline visible_context(lc::LoopContext) = @inline _visible_context(getcontext(lc), getruntimecontext(lc))

"""The lifetime of the run being prepared: only while init runs (for sizing); steps do not see it."""
@inline bundle_lifetime(ic::InitContext) = init_lifetime(ic)
bundle_lifetime(::LoopContext) = error("The lifetime is only known while init runs (for sizing, e.g. `processsizehint!`); steps do not see it.")

"""
The bundle after a merge: `stored` as the new stored context, and the runtime values in `runtime_patch`
(`(; part = (; name = value, ...), ...)`) merged into the runtime context. An init merge has no runtime values.
"""
@inline _rebundle(lc::LoopContext, stored::ProcessContext, runtime_patch::NamedTuple) =
    LoopContext(stored, (@inline merge_runtime_subcontexts(getruntimecontext(lc), runtime_patch)))
@inline _rebundle(ic::InitContext, stored::ProcessContext, ::NamedTuple{()}) = withstored(ic, stored)
