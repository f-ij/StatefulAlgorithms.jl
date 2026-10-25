#=
How an `OnChange` extends the base of reading and writing stored values (Context/View/Hooks.jl): it reads and shows as
the value it holds, and a write merges a new `OnChange` with the same callback and condition, and runs the callback after
the merge when the condition holds for the held and the merged value.
=#

"""An `OnChange` reads as the value it holds."""
@inline read_value(reader::R, w::OnChange) where {R<:AbstractContext} = DirectRead(getfield(w, :value))

"""
A write to an `OnChange` merges the new value wrapped again, and after the merge runs the callback when the condition
holds for the held and the new value (`run_on_change`).
"""
@inline function write_value(view::V, w::OnChange{T}, request::StoreInto{L}) where {V<:SubContextView, T, L}
    old = getfield(w, :value)
    new = convert(T, getfield(request, :value))
    callback, condition = getfield(w, :callback), getfield(w, :condition)
    return (DirectWrite{L}(OnChange(new, callback, condition)), AfterMerge(run_on_change, (condition, callback, old, new)))
end

"""An `OnChange` shows as the value it holds."""
@inline shown_value(w::OnChange) = shown_value(getfield(w, :value))
