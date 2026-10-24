#=
How declared locals extend the base of reading and writing stored values (Context/View/Hooks.jl): a placeholder (a local
without a value that was never written: `undef`, `UndefLocal{T}`) reads as an error.
=#

_throw_undef() = throw(UndefRefError())

# Reads: through a view and from a `ProcessContext` (a `Var`, `context.x`) alike.
@inline read_value(reader::R, ::UndefLocal) where {R<:AbstractContext} = _throw_undef()
# A local declared without a value that no step ever writes keeps its `undef`.
@inline read_value(view::V, ::UndefInitializer) where {V<:SubContextView} = _throw_undef()

# Shown after the run (`final_context`): a typed local never written shows as `undef`, as an untyped one does.
@inline shown_value(::UndefLocal) = undef
