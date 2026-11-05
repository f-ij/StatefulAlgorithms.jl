#=
Interface of `AbstractProcess`: what every process provides. A process runs in sessions (Sessions/Sessions.jl); its
loop counter is that of its current (or last) session.
=#

loopidx(p::AbstractProcess) = loopidx(getsession(p))
setloopidx!(p::AbstractProcess, value) = setloopidx!(getsession(p), value)
reset_loopidx!(p::AbstractProcess) = reset_loopidx!(getsession(p))

"""The number of steps `p`'s current or last run has made plus one, as an `Int` (exported: the user's loop index)."""
getlidx(p::AbstractProcess) = loopint(getsession(p))

export getlidx

"""How many repeats `p` runs: those of its lifetime (`Inf` for an indefinite one)."""
repeats(p::AbstractProcess) = repeats(getlifetime(p))

"""The start and close listeners of `p`: none by default; a `Process` has its own (`runtimelisteners(p::Process)`)."""
runtimelisteners(p::P) where {P<:AbstractProcess} = nothing

