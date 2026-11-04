#=
The status of a `TimedProcess` as the user asks for it: running or paused.
=#

"""Whether `tp`'s timer is running."""
isrunning(tp::TimedProcess) = !isnothing(tp.timer)

"""Whether `tp` has a paused run: one that `run(tp)` resumes."""
ispaused(tp::TimedProcess) = isnothing(tp.timer) && !isnothing(getruntimecontext(tp))
