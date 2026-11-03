#=
The context of any process: building a new one by replaying init on its plan (`makecontext`, `makecontext!`), cleanup,
and the context-exchange calls on a process (`isinteractive`, `interact!`, which go to its context;
Interactive/ContextExchange.jl). A `Process` stores its state context through its accessors (Process/Accessors.jl).
=#

function makecontext(p::AbstractProcess, inputs_overrides...; lifetime=nothing)
    lt = isnothing(lifetime) ? StatefulAlgorithms.lifetime(p) : lifetime
    getcontext(init(getalgo(p), inputs_overrides...; lifetime = lt))
end
"""Build a fresh context for a process by replaying lifecycle init on its LA."""
function makecontext!(p::AbstractProcess, inputs_overrides...; lifetime=nothing)
    c = makecontext(p, inputs_overrides...; lifetime)
    setcontext!(p, c)
end

function cleanup(p::AbstractProcess)
    lifetime = tasklifetime(p)
    returncontext = cleanup(getalgo(p), (;process = p, lifetime, getcontext(p)...))
    return deletekeys(returncontext, :process, :lifetime)
end

@inline isinteractive(process::AbstractProcess) = isinteractive(getcontext(process))

interact!(process::AbstractProcess, pair::Pair{Symbol, <:Any}; exchange::Union{Nothing, Symbol} = nothing) =
    interact!(getcontext(process), pair; exchange)
