#=
How a `TimedProcess` is shown.
=#

function Base.show(io::IO, tp::TimedProcess)
    state = isrunning(tp) ? "Running" : ispaused(tp) ? "Paused" : "Idle"
    print(io, state, " TimedProcess(", _process_algo_summary(tp), ", interval=", tp.interval, ", lifetime=", getlifetime(tp), ", loopidx=", getlidx(tp), ")")
    return nothing
end
