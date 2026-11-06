#=
Calls on a process's context that work for every process type: `init!`'s shared work, the specs a new process keeps,
cleanup, and sending a value to a `ContextExchange` (`interact!`, inactive).
=#

export init!

"""
    _init_process_context(p, specs) -> (context, stored_specs)

The work of `init!(p, specs...)` and `init(ip, specs...)`, without storing anything. The new specs are merged per target
over the process's stored specs (later ones win), and that merge is what the process keeps (`init(ip, ...)` builds a
new `InlineProcess` with it). Without an `Only` every `init` runs from the merged specs on an empty context (as
`setup`, with the process's lifetime); with `Only(A, B)` only A's and B's `init` run on the process's current context (`init(plan, context, Only(...), ...)`).
"""
function _init_process_context(p::AbstractProcess, specs::S) where {S<:Tuple}
    plan = strip_keymap(getalgo(p))   # `init` runs without the map; the context it gives gets the plan's registry back
    reg = getregistry(plan)
    only, rest = _split_only(reg, specs)
    inits, overrides, interactives = _merged_lifecycle_specs(reg, (getspecs(p)..., rest...))
    stored = (inits..., overrides..., interactives...)
    context = isnothing(only) ? _init_context_for(plan, inits, overrides, interactives, getlifetime(p)) : _init_again(plan, _getcontext_nokeymap(p), only, rest...)
    return with_plan_registry(p, context), stored
end

"""
    with_plan_registry(p, x) -> x with the map

`x`, a context or result from the loop's side (no registry), with the registry of `p`'s plan, which has the plan's
`UniqueKeyMap`: the way back from the loop to what the process keeps and hands out. Another value as it is. Untyped.
"""
Base.@nospecializeinfer function with_plan_registry(@nospecialize(p::AbstractProcess), @nospecialize(x))
    x isa ProcessContext || return x
    return ProcessContext(get_subcontexts(x), getregistry(getalgo(p)))
end

"""
    _getcontext_nokeymap(p)

The process's context without the plan's `UniqueKeyMap` (`strip_keymap`), for SA's own code that runs on it outside the
loop. What the user gets, and what the process keeps, is `getcontext(p)`, with the map.
"""
Base.@nospecializeinfer _getcontext_nokeymap(@nospecialize(p::AbstractProcess)) = strip_keymap(getcontext(p))

"""
    _stored_specs(plan, specs) -> Tuple

The specs a new process keeps: `specs` resolved against the plan's registry and merged per target (later ones win), so
`init!` can merge new ones over them.
"""
function _stored_specs(plan::LA, specs::S) where {LA<:AbstractLoopAlgorithm, S<:Tuple}
    isempty(specs) && return ()
    inits, overrides, interactives = _merged_lifecycle_specs(getregistry(plan), specs)
    return (inits..., overrides..., interactives...)
end

function cleanup(p::AbstractProcess)
    lifetime = tasklifetime(p)
    returncontext = cleanup(strip_keymap(getalgo(p)), (;process = p, lifetime, _getcontext_nokeymap(p)...))
    return deletekeys(returncontext, :process, :lifetime)
end

@inline isinteractive(process::AbstractProcess) = isinteractive(_getcontext_nokeymap(process))

# Inactive: no plan uses a `ContextExchange` (Interactive/ContextExchange.jl; TODO.md, "`ContextExchange`: probably delete it").
interact!(process::AbstractProcess, pair::Pair{Symbol, <:Any}; exchange::Union{Nothing, Symbol} = nothing) =
    interact!(_getcontext_nokeymap(process), pair; exchange)
