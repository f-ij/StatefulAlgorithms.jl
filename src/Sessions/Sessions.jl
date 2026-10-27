#=
Process sessions: what the loop runs with instead of the process the user holds.

A process (`Process`, `InlineProcess`) is the user's handle: it holds the plan, its context and the plan's
`UniqueKeyMap` as a type, so what the user does with it is typed (`run(p; lifetime)` numbers the lifetime while
compiling; `context(ip)[handle]`; a `Process`'s `context(p)` is a stored context, as its type may change between runs). The
loop and the steps get a `ProcessSession` instead: the run's mutable record (its counters, and for an interactive
process the times, the pause and stop flags and the resume point), shared with the process, and with no map in its
type. The plan, the context and the lifetime go to the loop without the map as well, so the loop is compiled once for
every set of `Unique` handles, while the process the user holds is fully typed.

Each way of running has its own session type, as each has its own process type:

| Session              | Made by                                   | Holds                                                     |
|:---------------------|:------------------------------------------|:----------------------------------------------------------|
| `InlineSession`      | `InlineProcess` (once), `run(plan)` (per run) | loop counter                                          |
| `InteractiveSession` | `Process` (with it; a new one for a run with a lifetime of another type) | also ticks, the start and end time, the `shouldrun` and `paused` flags, the cursor of a paused run, the thread |

Interface.jl: what every session provides (the loop counter; the times, kept only by
`InteractiveSession`). Hooks.jl: the stop check
(`process_breakcondition`).
=#

"""
    ProcessSession

The run of a process as the loop sees it: what the loop and the steps read and write while it runs (counters, and
for an interactive process the times and the stop and pause flags), shared with the process the user holds. The loop, the steps
and the lifetimes take a session, never the process, so no type the loop is compiled for has the plan's
`UniqueKeyMap` in it. A subtype per way of running (`InlineSession`, `InteractiveSession`).
"""
abstract type ProcessSession end

export ProcessSession
