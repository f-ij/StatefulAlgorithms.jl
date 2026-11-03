#=
Interface of `AbstractProcess`: what every process provides. A process runs in sessions (Sessions/Sessions.jl); its
loop counter is that of its current (or last) session.
=#

"""The session of `p`'s current or last run (`InlineSession`, `InteractiveSession`); see Sessions/Sessions.jl."""
@inline getsession(p::AbstractProcess) = getfield(p, :session)

loopidx(p::AbstractProcess) = loopidx(getsession(p))
setloopidx!(p::AbstractProcess, value) = setloopidx!(getsession(p), value)
reset_loopidx!(p::AbstractProcess) = reset_loopidx!(getsession(p))

loopint(p::AbstractProcess) = loopint(getsession(p))
getlidx(p::AbstractProcess) = loopint(p)

export getlidx

"""How many repeats `p` runs: those of its lifetime (`Inf` for an indefinite one)."""
repeats(p::AbstractProcess) = repeats(lifetime(p))

"""The start and close listeners of `p`: none by default; a `Process` has its own (`runtimelisteners(p::Process)`)."""
runtimelisteners(p::P) where {P<:AbstractProcess} = nothing

function Base.run(p::AP, lifetime = nothing, inputs_and_overrides...; kwargs...) where AP <: AbstractProcess
    @assert isidle(p) "Process is already in use"
    makeloop!(p, (; kwargs...))
end
