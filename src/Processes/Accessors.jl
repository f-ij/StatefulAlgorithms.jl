#=
Getters shared by every process type.
=#

"""The session of `p`'s current or last run (`InlineSession`, `InteractiveSession`); see Sessions/Sessions.jl."""
getsession(@nospecialize(p::AbstractProcess)) = getfield(p, :session)
