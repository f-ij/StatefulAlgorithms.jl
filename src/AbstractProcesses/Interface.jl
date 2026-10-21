#=
Interface of `AbstractProcess`: what every process provides (its loop counter), with defaults that a process type can
overload. The process's stop check is a hook: Hooks.jl (`process_breakcondition`).
=#

loopidx(p::AbstractProcess) = p.loopidx
setloopidx!(p::AbstractProcess, value) = (p.loopidx = value)
reset_loopidx!(p::AbstractProcess) = setloopidx!(p, oneunit(loopidx(p)))

loopint(p::AbstractProcess) = Int(loopidx(p))
getlidx(p::AbstractProcess) = loopint(p)

@inline inc!(p::AbstractProcess) = p.loopidx += oneunit(p.loopidx)
@inline tick!(p::AbstractProcess) = nothing

export loopidx, loopint, getlidx, inc!
