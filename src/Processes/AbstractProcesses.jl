abstract type AbstractProcess end

"""
    InteractiveProcess{F, C}

A process the user can pause, resume and close while it runs: it holds its plan (`F`), its state context and, while a
run is paused, that run's runtime context, and it runs in an `InteractiveSession{C}` (`C`: the plan's cursor type).
Written so `Process` (a run on its own task) and `TimedProcess` (one step per `Timer` tick) share their accessors
(Processes/Process/Accessors.jl), `prepare_for_loop` (Processes/Process/Loop.jl) and the cleanup of a
paused run (`_cleanup_paused_process!`).
"""
abstract type InteractiveProcess{F, C} <: AbstractProcess end

export AbstractProcess
