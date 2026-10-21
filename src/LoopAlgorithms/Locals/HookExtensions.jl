#=
How declared locals extend the base of reading and writing stored values (Context/View/Hooks.jl): a `Maybe` reads
and shows as its value, or as `nothing` / an error while unset; a `LocalProbe` reads as a value of its type so far,
for inference.
=#

_throw_undef() = throw(UndefRefError())

# Reads: a `Maybe` reads as its value, or as `nothing` / an error while unset.
# Through a view and from a `ProcessContext` (a `Var`, `context.x`) alike.
@inline read_value(reader::R, m::Maybe{T, F, Nothing}) where {R<:AbstractContext, T, F} =
    !iszero(getfield(m, :isset)) ? DirectRead(getfield(m, :value)) : DirectRead(nothing)
@inline read_value(reader::R, m::Maybe{T, F, UndefInitializer}) where {R<:AbstractContext, T, F} =
    !iszero(getfield(m, :isset)) ? DirectRead(getfield(m, :value)) : _throw_undef()
# A local declared without a value that no step ever writes keeps its `undef`.
@inline read_value(view::V, ::UndefInitializer) where {V<:SubContextView} = _throw_undef()

# Shown after the run (`final_context`): a `Maybe` shows as its value, or as `nothing` while unset.
@inline shown_value(m::Maybe) = iszero(getfield(m, :isset)) ? nothing : shown_value(getfield(m, :value))

# Inference only (Locals.jl section 4): a probe reads as a value of the local's type so far.
@inline read_value(view::V, ::LocalProbe{T, UndefInitializer}) where {T, V<:SubContextView} =
    T === Union{} ? _throw_undef() : DirectRead{T}(_pretend_value(T))
@inline read_value(view::V, ::LocalProbe{T, Nothing}) where {T, V<:SubContextView} =
    DirectRead{Union{Nothing, T}}(_pretend_value(Union{Nothing, T}))
"""Return a value that inference treats as being of type `T`."""
_pretend_value(::Type{T}) where {T} = Base.inferencebarrier(nothing)::T
