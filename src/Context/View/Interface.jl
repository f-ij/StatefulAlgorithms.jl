#=
Extendable API of views: functions packages overload to change what a view shows or writes back for a stored value.
=#

"""
    subcontext_view_value(value, view)

Return the value exposed by `SubContextView` reads for one stored field.

This is an overloadable API for storage wrappers that need custom
algorithm-facing read behavior. Methods should transform `value` and then call
`subcontext_view_value(next_value, view)` again, so nested wrappers unfold until
the default identity method is reached.
"""
@inline subcontext_view_value(value::T, view::V) where {T, V<:SubContextView} = value

"""
    subcontext_writeback_value(old, returned)

Return the value that should be written to context when an algorithm returns
`returned` for a field currently storing `old`.

This is an overloadable API for storage wrappers that absorb writes while
preserving their context representation, for example mutable reference wrappers.
"""
@inline subcontext_writeback_value(::Any, returned) = returned
