#=
What a user calls on an `InlineProcess`: `run` (and `run_nogen`, the same without the `inlined` choice), `init`,
`reset` and `init_and_run`. Each one that changes the process returns a new `InlineProcess` (no `!`).
=#

export run, reset

"""
    run(ip; context, repeats, lifetime, inlined = Val(false), inputs...)

One run of `ip` in the caller's task, from the context it holds (or `context`, which becomes its context), returning
the run's result. `inlined = Val(true)` pastes the loop into `run(ip)`: the context is not passed into a call and back
(57-62 instead of 121-150 ns per `run(ip)` for the 616-byte context of the 3D Ising model with one step per run,
measured on `refactor/plan-compiles`), but the loop's machine code is then made again for every caller, while the
default call into the loop (`run_session_loop`) is compiled once. As a `Val`, the branch is decided while compiling.
"""
@inline function Base.run(p::InlineProcess, inputs_overrides...; context = nothing, repeats=nothing, lifetime=nothing, inlined::Val = Val(false), kwargs...)
    algo = getalgo(p)
    _set_inline_run_context!(p, context)
    runtime_inputs = _inline_runtime_inputs(algo, inputs_overrides, (; kwargs...))
    # A lifetime from outside the plan gets the plan's numbers (`number_by_keymap`) and its `Var`s their context keys
    # (`resolve_var_keys`), while compiling, before the call to the loop. The process's own lifetime has its keys from
    # when the process was built, so it stays as it is.
    run_lifetime = resolve_var_keys(something(parse_lifetime(isnothing(lifetime) ? lifetime : number_by_keymap(lifetime, getfield(getregistry(getalgo(p)), :keymap)), repeats), StatefulAlgorithms.getlifetime(p)), getcontext(p))
    return @inline _run_inline!(p, run_lifetime, runtime_inputs, inlined)
end

@inline function run_nogen(p::InlineProcess, inputs_overrides...; context = nothing, repeats=nothing, lifetime=nothing, kwargs...)
    algo = getalgo(p)
    _set_inline_run_context!(p, context)
    # A lifetime from outside the plan gets the plan's numbers (`number_by_keymap`) and its `Var`s their context keys
    # (`resolve_var_keys`), while compiling, before the call to the loop. The process's own lifetime has its keys from
    # when the process was built, so it stays as it is.
    run_lifetime = resolve_var_keys(something(parse_lifetime(isnothing(lifetime) ? lifetime : number_by_keymap(lifetime, getfield(getregistry(getalgo(p)), :keymap)), repeats), StatefulAlgorithms.getlifetime(p)), getcontext(p))
    runtime_inputs = _inline_runtime_inputs(algo, inputs_overrides, (; kwargs...))
    return @inline _run_inline!(p, run_lifetime, runtime_inputs, Val(false))
end

"""
    init(ip, InitArgs(...), Override(...)) -> InlineProcess
    init(ip, Only(A, B), InitArgs(...), Override(...)) -> InlineProcess

A new `InlineProcess` with the same plan and lifetime whose context comes from running `init` again: all of them,
from `ip`'s specs with `specs` merged over them, or only the ones `Only` names, on `ip`'s current context. The new
process keeps the merged specs. `ip` itself is left as it was.

No `init!`: an `InlineProcess`'s specs and context are typed fields (type parameters `S` and `ContextType`), and new
specs can change those types, so the result is a new process. The rule for every process function: one that changes
typed data has no `!` and returns a new process (as `setlifetime(ip, lt)`).
"""
function init(ip::IP, specs::Vararg{InputInterface}) where {IP<:InlineProcess}
    context, stored = _init_process_context(ip, specs)
    return _construct_inline_process(getalgo(ip), context, stored, getlifetime(ip))
end

"""
    reset(ip, InitArgs(...), Override(...)) -> InlineProcess

A new `InlineProcess` with the same plan and lifetime and a fresh context, set up (`setup`) from `ip`'s specs with
`specs` merged over them; the new process keeps the merged specs and its loop counter starts at 1. `ip` itself is
left as it was. No `!`, as for every call that changes an `InlineProcess` (see `init(ip, ...)`). `Only` is not
accepted: `init(ip, Only(...), ...)` runs a subset of the `init` functions.
"""
function Base.reset(ip::IP, specs::Vararg{InputInterface}) where {IP<:InlineProcess}
    plan = getalgo(ip)
    stored = _stored_specs(plan, (getspecs(ip)..., specs...))
    context = first(_setup(plan, stored...; lifetime = getlifetime(ip)))
    return _construct_inline_process(plan, with_keymap(context, getkeymap(plan)), stored, getlifetime(ip))
end

"""
    init_and_run(ip, specs...)

`run(init(ip, specs...))`: the run's result. `ip` itself is left as it was.
"""
@inline function init_and_run(ip::IP, specs::Vararg{InputInterface}) where {IP<:InlineProcess}
    return run(init(ip, specs...))
end
