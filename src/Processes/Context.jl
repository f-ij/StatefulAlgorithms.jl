#=
Calls on a process's context that work for every process type: `init!`'s shared work and a new context from the plan
and the process's specs (`_setup_from_stored_specs`), cleanup, and sending a value to a `ContextExchange` (`interact!`,
inactive).
=#

export init!

"""
    _init_process_context(p, specs) -> (context, stored_specs)

The work of `init!(p, specs...)` for every process type, without storing anything. The new specs are merged per target
over the process's stored specs (later ones win), and that merge is what `Process` and `TimedProcess` keep (an
`InlineProcess`'s specs are fixed). Without an `Only` every `init` runs from the merged specs on an empty context (as
`setup`, with the process's lifetime); with `Only(A, B)` only A's and B's `init` run on the process's current context (`init(plan, context, Only(...), ...)`).
"""
function _init_process_context(p::AbstractProcess, specs::S) where {S<:Tuple}
    plan = getalgo(p)
    reg = getregistry(plan)
    only, rest = _split_only(reg, specs)
    inits, overrides, interactives = _merged_lifecycle_specs(reg, getspecs(p), rest)
    stored = (inits..., overrides..., interactives...)
    context = isnothing(only) ? _init_context_for(plan, inits, overrides, interactives, getlifetime(p)) : init(plan, getcontext(p), only, rest...)
    return context, stored
end

"""
    _setup_from_stored_specs(p, specs...; lifetime = getlifetime(p)) -> context

A new context for `p` from an empty one, every `init` running: from the process's stored specs with `specs` merged over
them (`reset!(ip)`, the error path of `close`). The stored specs are already resolved and are not
looked up by name again (a lookup by name in the precompile workload makes the package image fail to load on Julia
1.13.1).
"""
function _setup_from_stored_specs(p::AbstractProcess, specs...; lifetime = getlifetime(p))
    plan = getalgo(p)
    inits, overrides, interactives = _merged_lifecycle_specs(getregistry(plan), getspecs(p), specs)
    return _init_context_for(plan, inits, overrides, interactives, lifetime)
end

"""
    _stored_specs(plan, specs) -> Tuple

The specs a new process keeps: `specs` resolved against the plan's registry and merged per target (later ones win), so
`init!` can merge new ones over them.
"""
function _stored_specs(plan::LA, specs::S) where {LA<:AbstractLoopAlgorithm, S<:Tuple}
    isempty(specs) && return ()
    inits, overrides, interactives = _merged_lifecycle_specs(getregistry(plan), (), specs)
    return (inits..., overrides..., interactives...)
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
