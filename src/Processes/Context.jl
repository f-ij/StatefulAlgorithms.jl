#=
Calls on a process's context that work for every process type: making a new context with `setup` from the plan and
the process's specs (`makecontext`, `makecontext!`), cleanup, and sending a value to a `ContextExchange` (`interact!`, inactive).
=#

function makecontext(p::AbstractProcess, inputs_overrides...; lifetime=nothing)
    lt = isnothing(lifetime) ? StatefulAlgorithms.lifetime(p) : lifetime
    first(setup(getalgo(p), getspecs(p)..., inputs_overrides...; lifetime = lt))
end
"""Build a fresh context for a process with `setup`, from its plan, the specs it was built with and `inputs_overrides`."""
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

# Inactive: no plan uses a `ContextExchange` (Interactive/ContextExchange.jl; TODO.md, "`ContextExchange`: probably delete it").
interact!(process::AbstractProcess, pair::Pair{Symbol, <:Any}; exchange::Union{Nothing, Symbol} = nothing) =
    interact!(getcontext(process), pair; exchange)
