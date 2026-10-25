#=
How an `OnChange` extends the base of reading and writing stored values (Context/View/Hooks.jl): it reads and shows as
the value it holds, and a write compares the merged value with the held one, runs the callback when they differ, and
merges a new `OnChange` with the same callback.
=#

"""An `OnChange` reads as the value it holds."""
@inline read_value(reader::R, w::OnChange) where {R<:AbstractContext} = DirectRead(getfield(w, :value))

"""A write to an `OnChange` runs its callback when the value changes (`old !== new`), and merges the new value wrapped again."""
@inline function write_value(view::V, w::OnChange{T}, request::StoreInto{L}) where {V<:SubContextView, T, L}
    old = getfield(w, :value)
    new = convert(T, getfield(request, :value))
    old !== new && getfield(w, :callback)(old, new)
    return DirectWrite{L}(OnChange(new, getfield(w, :callback)))
end

"""An `OnChange` shows as the value it holds."""
@inline shown_value(w::OnChange) = shown_value(getfield(w, :value))
