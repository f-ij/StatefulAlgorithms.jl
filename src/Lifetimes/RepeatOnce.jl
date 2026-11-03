#=
`RepeatOnce`: one repeat, with the count in the type. No condition of its own: the default stop check.
=#

"""
A single repeat: `Repeat(1)` whose type says the count. A routine stores a `Repeat(1)` child as `RepeatOnce()`
(`store_single_repeats_as_repeat_once`), so its step is compiled without a loop; any other count is a value, so a new
count does not compile the routine again.
"""
struct RepeatOnce <: RepeatLifetime end
repeats(::RepeatOnce) = 1
