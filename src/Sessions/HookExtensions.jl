#=
The sessions' answers to the session hooks (Hooks.jl).
=#

"""
    process_breakcondition(session::InteractiveSession) -> Bool

An interactive run is interrupted when its `shouldrun` flag is off (`pause(p)` or `close(p)`). Checked after every step
and after every routine repeat. Routine repeats can run for a very long time, so the check must stay per repeat:
checking only once per routine child (or every n repeats) would make a pause or close wait for the child's remaining
repeats and kill interactivity. The check costs a little per repeat and keeps the compiler from writing a routine's
repeats out one after another (perf/README.md shows the cost).
"""
@inline process_breakcondition(session::S) where {S<:InteractiveSession} = @inline !shouldrun(session)
