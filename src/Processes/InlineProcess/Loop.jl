#=
Loop setup of an `InlineProcess`: the run's inputs and starting context, what a run hands to the loop
(`prepare_for_loop`) and one run in the caller's task (`_run_inline!`).
=#

"""
The runtime inputs for one `InlineProcess` execution; they are checked against the plan's `@input`s where the run's
`LoopContext` is made (`prepare_for_loop`).

`InlineProcess` has a fixed context type after construction. Per-run data is
therefore limited to declared `@input` keywords; init values go through `init!(ip, ...)` (or `reset!`), where the
process rebuilds its persistent context.
"""
@inline function _inline_runtime_inputs(algo::A, inputs_overrides::IO, kwargs::K) where {A<:AbstractLoopAlgorithm, IO<:Tuple, K<:NamedTuple}
    isempty(inputs_overrides) || error("InlineProcess run accepts runtime inputs as keywords only. Use init!(ip, InitArgs(...), ...) to initialize the context again.")
    return kwargs
end

# A context given to `run(ip)`: the run starts from it, so it becomes the process's context first.
@inline _set_inline_run_context!(p::InlineProcess, ::Nothing) = nothing
@inline function _set_inline_run_context!(p::InlineProcess, context)
    @assert context isa contexttype(p) "Wrong context shape for this process\n Context is of type $(typeof(context)), but expected $(contexttype(p))."
    p.context = context
    return nothing
end

"""
    prepare_for_loop(ip::InlineProcess, context, inputs, resume)

An `InlineProcess` run runs in the process's one session, on its plan, from `context` and the run's inputs
(Processes/Hooks.jl). An `InlineProcess` cannot pause, so it never resumes.
"""
@inline prepare_for_loop(ip::IP, context::C, inputs::I, resume::Resuming{false}) where {IP<:InlineProcess, C<:ProcessContext, I<:NamedTuple} =
    getsession(ip), getalgo(ip), (@inline with_inputs((@inline LoopContext(getalgo(ip), context)), getalgo(ip), inputs))

"""
One run of `p`: what `prepare_for_loop` makes (the session, the plan, the `LoopContext`), then the loop with those as
arguments, the same entry as a `Process` run (`run_session_loop`; with `Val(true)`, the loop pasted in). The context it
gives back becomes the process's.
"""
@inline function _run_inline!(p::InlineProcess, run_lifetime::LT, runtime_inputs::I, ::Val{inlined}) where {LT, I, inlined}
    session, algo, lc = @inline prepare_for_loop(p, getcontext(p), runtime_inputs, Resuming{false}())
    persistent_context, result = if inlined
        @inline loop(session, algo, lc, run_lifetime, Resuming{false}())
    else
        run_session_loop(loop, session, algo, lc, run_lifetime)
    end
    p.context = persistent_context
    return result
end
