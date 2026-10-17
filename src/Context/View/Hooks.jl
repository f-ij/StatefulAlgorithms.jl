#=
Extendable API of views: functions packages overload to change what a view shows or writes back for a stored value,
and what the context after a run (`final_context`) shows for it.
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

"""
    shown_value(stored) -> value

The value the context after a run (`final_context`) shows for the value `stored`: `stored` itself by default. Unlike
`view_value` there is no view and it never throws: a storage wrapper that may hold no value (a declared local's
`Maybe`) shows `nothing` then, and otherwise unwraps one layer and calls `shown_value(inner)` again.
"""
@inline shown_value(stored::S) where {S} = stored
