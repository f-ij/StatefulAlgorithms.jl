#=
What a user calls on an `InlineProcess`: `run` (and `run_nogen`, the same without the `inlined` choice), `reset!` and
`init_and_run`.
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
    run_lifetime = something(parse_lifetime(nothing, lifetime, repeats), StatefulAlgorithms.lifetime(p))
    return @inline _run_inline!(p, run_lifetime, runtime_inputs, inlined)
end

@inline function run_nogen(p::InlineProcess, inputs_overrides...; context = nothing, repeats=nothing, lifetime=nothing, kwargs...)
    algo = getalgo(p)
    _set_inline_run_context!(p, context)
    run_lifetime = something(parse_lifetime(nothing, lifetime, repeats), StatefulAlgorithms.lifetime(p))
    runtime_inputs = _inline_runtime_inputs(algo, inputs_overrides, (; kwargs...))
    return @inline _run_inline!(p, run_lifetime, runtime_inputs, Val(false))
end

@inline function reset!(p::InlineProcess, inputs_overrides...)
    reset_loopidx!(getsession(p))
    p.context = first(setup(getalgo(p), getspecs(p)..., inputs_overrides...; lifetime = lifetime(p)))
    # TODO: Probably remove consumed flag
    p.consumed = false
    return true
end

@inline function init_and_run(p::InlineProcess, inputs_overrides...)
    @inline makecontext!(p, inputs_overrides...)
    return run(p)
end
