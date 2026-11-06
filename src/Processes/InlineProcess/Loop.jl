#=
Loop setup of an `InlineProcess`: the run's inputs and starting context, what a run hands to the loop
(`prepare_for_loop`) and one run in the caller's task (`_run_inline!`).
=#

"""
The runtime inputs for one `InlineProcess` execution; they are checked against the plan's `@input`s where the run's
`LoopContext` is made (`prepare_for_loop`).

`InlineProcess` has a fixed context type after construction. Per-run data is
therefore limited to declared `@input` keywords; init values go through `init(ip, ...)` or `reset(ip, ...)`, which return a new process with the new context.
"""
@inline function _inline_runtime_inputs(algo::A, inputs_overrides::IO, kwargs::K) where {A<:AbstractLoopAlgorithm, IO<:Tuple, K<:NamedTuple}
    isempty(inputs_overrides) || error("InlineProcess run accepts runtime inputs as keywords only. Use init(ip, InitArgs(...), ...), which returns a new InlineProcess, to initialize the context again.")
    return kwargs
end

# A context given to `run(ip)`: the run starts from it, so it becomes the process's context first.
@inline _set_inline_run_context!(p::InlineProcess, ::Nothing) = nothing
@inline function _set_inline_run_context!(p::InlineProcess, context)
    @assert context isa contexttype(p) "Wrong context shape for this process\n Context is of type $(typeof(context)), but expected $(contexttype(p))."
    setcontext!(p, context)
    return nothing
end

"""
    prepare_for_loop(ip::InlineProcess, context, inputs, resume)

An `InlineProcess` run runs in the process's one session, on its plan, from `context` and the run's inputs
(Processes/Hooks.jl). An `InlineProcess` cannot pause, so it never resumes. The loop gets plan and context without the
plan's `UniqueKeyMap` (`strip_keymap_typed`), and the context without its registry (`LoopContext(plan, context)` drops
it), so `loop` compiles once for every set of `Unique` handles.
"""
@inline function prepare_for_loop(ip::IP, context::C, inputs::I, resume::Resuming{false}) where {IP<:InlineProcess, C<:ProcessContext, I<:NamedTuple}
    algo = strip_keymap_typed(getalgo(ip))
    return getsession(ip), algo, (@inline with_inputs((@inline LoopContext(algo, context)), algo, inputs))
end

"""
One run of `p`: what `prepare_for_loop` makes (the session, the plan, the `LoopContext`), then the loop with those as
arguments, the same entry as a `Process` run (`run_session_loop`; with `Val(true)`, the loop pasted in). The values of
the context it gives back become the process's; the result comes back with the plan's registry (`with_plan_registry`),
so `run(ip)[handle]` is found from types.
"""
@inline function _run_inline!(p::InlineProcess, run_lifetime::LT, runtime_inputs::I, ::Val{inlined}) where {LT, I, inlined}
    session, algo, lc = @inline prepare_for_loop(p, getcontext(p), runtime_inputs, Resuming{false}())
    persistent_context, result = if inlined
        @inline loop(session, algo, lc, run_lifetime, Resuming{false}())
    else
        run_session_loop(loop, session, algo, lc, run_lifetime)
    end
    # The new values into the process's context, which keeps its registry with the map.
    p.context = withsubcontexts(getcontext(p), get_subcontexts(persistent_context))
    return @inline with_plan_registry(p, result)
end

"""
    with_plan_registry(ip::InlineProcess, x)

A context the loop gives back (`x`, without a registry) with the registry of `ip`'s context, which has the plan's
`UniqueKeyMap`. Typed. A value that is not a context as it is. (The untyped method for any process is in
Processes/Context.jl.)
"""
@inline with_plan_registry(ip::InlineProcess, c::ProcessContext{D}) where {D} =
    ProcessContext{D, typeof(getregistry(getcontext(ip)))}(get_subcontexts(c), getregistry(getcontext(ip)))
@inline with_plan_registry(ip::InlineProcess, x) = x
