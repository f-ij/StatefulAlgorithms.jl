#=
What a user calls on an `InlineProcess`: `run` (and `run_nogen`, the same without the `inlined` choice), `init!`,
`reset!` and `init_and_run`.
=#

export run, reset!

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
    run_lifetime = something(parse_lifetime(lifetime, repeats), StatefulAlgorithms.getlifetime(p))
    return @inline _run_inline!(p, run_lifetime, runtime_inputs, inlined)
end

@inline function run_nogen(p::InlineProcess, inputs_overrides...; context = nothing, repeats=nothing, lifetime=nothing, kwargs...)
    algo = getalgo(p)
    _set_inline_run_context!(p, context)
    run_lifetime = something(parse_lifetime(lifetime, repeats), StatefulAlgorithms.getlifetime(p))
    runtime_inputs = _inline_runtime_inputs(algo, inputs_overrides, (; kwargs...))
    return @inline _run_inline!(p, run_lifetime, runtime_inputs, Val(false))
end

"""
    init!(ip, InitArgs(...), Override(...)) -> ip
    init!(ip, Only(A, B), InitArgs(...), Override(...)) -> ip

Runs `init` again (all of them, from the specs the process was built with and `specs` merged over them, or only the
ones `Only` names, on the current context) and makes the result the process's context. Unlike `init!(p::Process, ...)`
the process does not keep the merged specs: its specs are typed and fixed, and other specs for good mean a new
process. The loop counter is left alone (`reset!` restarts it).
"""
function init!(ip::InlineProcess, specs::InputInterface...)
    context, _ = _init_process_context(ip, specs)
    setcontext!(ip, context)
    return ip
end

@inline function reset!(p::InlineProcess, inputs_overrides...)
    reset_loopidx!(getsession(p))
    p.context = first(setup(getalgo(p), getspecs(p)..., inputs_overrides...; lifetime = getlifetime(p)))
    return true
end

@inline function init_and_run(p::InlineProcess, inputs_overrides...)
    init!(p, inputs_overrides...)
    return run(p)
end
