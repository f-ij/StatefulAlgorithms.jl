#=
Getters shared by every process type, and `set_user_context!`, which stores the context a process hands to the user.
=#

"""
    set_user_context!(process, c)

Builds the context `process` hands to the user from its context `c` (without the map): `c` with the plan's
`UniqueKeyMap` put back (`with_keymap`, from the process's `keymap`), stored in the process's `user_context` field, which
`getcontext` returns. Called each time the process's context changes. Untyped, so a loop exit that calls it compiles
nothing per set of `Unique` handles.
"""
Base.@nospecializeinfer function set_user_context!(@nospecialize(process::AbstractProcess), @nospecialize(c))
    setfield!(process, :user_context, with_keymap(c, getfield(process, :keymap)))
    return nothing
end

"""The session of `p`'s current or last run (`InlineSession`, `InteractiveSession`); see Sessions/Sessions.jl."""
getsession(@nospecialize(p::AbstractProcess)) = getfield(p, :session)
