#=
Extendable API of views: functions packages overload to change what a view shows or writes back for a stored value.
=#

"""
    view_value(view, stored) -> value

The value `view` shows an algorithm for the value `stored` in one of its fields: `stored` itself by default. A storage
wrapper (`InteractiveVar`, `ReplacedVar`, a declared local's `Maybe`, ...) adds a method that unwraps one layer and
calls `view_value(view, inner)` again, so nested wrappers unfold until this default is reached. `view` is the
`SubContextView` the value is read through (as the container comes first in `getindex`), so a wrapper can read
elsewhere through it (`ReplacedVar`).
"""
@inline view_value(view::V, stored::S) where {V<:SubContextView, S} = stored

"""
    writeback_value(stored, returned) -> value

The value to store in a field that holds `stored` when a step returns `returned` for it: `returned` by default. A
storage wrapper that absorbs writes while keeping its place in the context adds a method (an `InteractiveVar` puts
`returned` into its reference and stays itself).
"""
@inline writeback_value(stored::S, returned::R) where {S, R} = returned
