#=
Interface of `ProcessSession`: what every session provides, its loop counter. What a session type can overload (the
stop check, ticks, times, pausing) is in Hooks.jl. A process gives its session with `getsession`, and forwards the
counter to it (`loopidx(p)`).
=#

loopidx(s::ProcessSession) = s.loopidx
@inline setloopidx!(s::ProcessSession, value) = (s.loopidx = value)
reset_loopidx!(s::ProcessSession) = setloopidx!(s, oneunit(loopidx(s)))

# `% Int`, not `Int(…)`: the loop reads this before every step (the lifetime's stop check), and a conversion that can
# throw makes LLVM store the counter to the session on every step, as the error could observe it.
loopint(s::ProcessSession) = loopidx(s) % Int

@inline inc!(s::ProcessSession) = s.loopidx += oneunit(s.loopidx)

export inc!
