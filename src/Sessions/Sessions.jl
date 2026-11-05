#=
`ProcessSession`: the mutable run state (loop counter; for `Process` also times and the pause/stop flags) that the
loop and the steps get in place of the process. Keeps process types out of the compiled loop.

Subtypes live with their process: `InlineSession` (Processes/InlineProcess/Session.jl), `InteractiveSession`
(Processes/Process/Session.jl). Interface.jl: the loop counter; Hooks.jl: the session hooks.
=#

"""
    ProcessSession

The run of a process as the loop sees it: what the loop and the steps read and write while it runs (counters, and
for an interactive process the times and the stop and pause flags), shared with the process the user holds. The loop, the steps
and the lifetimes take a session, never the process. A subtype per way of running (`InlineSession`,
`InteractiveSession`).
"""
abstract type ProcessSession end

export ProcessSession
