#=
A cache for one step only: building the context a process hands to the user (`context(p)`, `context(ip)`,
`fetch(p)`). A process runs on its context without the plan's `UniqueKeyMap` (HeldIds.jl); the user gets it with the map
put back (`with_keymap`), which makes a new registry, `Ref` and context on every call, about 330 ns. This cache keeps,
per process, the last context it built and the process context it built it from, and hands the built one out again
while the process context is still that one (`===`).

Only the built user context is cached; the map itself is in the registry and is not looked up here. Weak keys: an entry
goes away with its process.
=#

"""
    BuiltUserContext(from, user)

One entry of `USER_CONTEXT_CACHE`: `user`, the context handed to the user, built from the process context `from`.
"""
struct BuiltUserContext
    from::Any
    user::Any
end

"""The last context each process handed to the user (`BuiltUserContext`), keyed by the process."""
const USER_CONTEXT_CACHE = WeakKeyDict{AbstractProcess, BuiltUserContext}()

"""
    get_user_context(process, c, keymap) -> context

`c` (a context of `process`) with `keymap` put back (`with_keymap`): the one built last for `process` when it was built
from this `c`, else built now and stored in `USER_CONTEXT_CACHE`. Untyped.
"""
Base.@nospecializeinfer function get_user_context(@nospecialize(process::AbstractProcess), @nospecialize(c), @nospecialize(keymap))
    isnothing(keymap) && return c
    built = get(USER_CONTEXT_CACHE, process, nothing)
    built isa BuiltUserContext && built.from === c && return built.user
    user = with_keymap(c, keymap)
    USER_CONTEXT_CACHE[process] = BuiltUserContext(c, user)
    return user
end
