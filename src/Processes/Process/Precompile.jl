#=
Precompiling the loop of a `Process` run before its task exists (`precompile_loop!`).
=#

_is_generating_package_output() = ccall(:jl_generating_output, Cint, ()) != 0

@inline function precompile_loop!(loopfunc, p::Process{F, C}, func, lc, lt, resume::Resuming = Resuming{false}()) where {F, C}
    # The loop runs on the session of a run with this lifetime (`create_session`), not on the process.
    precompile_loop!(typeof(loopfunc), InteractiveSession{C, typeof(lt)}, typeof(func), typeof(lc), typeof(lt), typeof(resume))
    return nothing
end

@inline precompile_loop!(p::Process, func, lc, lt) = precompile_loop!(loop, p, func, lc, lt)

function _callable_instance(::Type{F}) where {F}
    return isdefined(F, :instance) ? getfield(F, :instance) : nothing
end

function precompile_loop!(
    loopfunc_type::Type,
    session_type::Type,
    func_type::Type,
    loop_context_type::Type,
    lifetime_type::Type,
    resume_type::Type,
)
    loopfunc = _callable_instance(loopfunc_type)
    isnothing(loopfunc) && return nothing
    Base.precompile(loopfunc, (session_type, func_type, loop_context_type, lifetime_type, resume_type, NonGenerated))
    return nothing
end

function _schedule_loop_precompile!(
    loopfunc_type::Type,
    session_type::Type,
    func_type::Type,
    loop_context_type::Type,
    lifetime_type::Type,
    resume_type::Type,
)
    if _is_generating_package_output()
        precompile_loop!(loopfunc_type, session_type, func_type, loop_context_type, lifetime_type, resume_type)
    else
        Threads.@spawn precompile_loop!(loopfunc_type, session_type, func_type, loop_context_type, lifetime_type, resume_type)
    end
    return nothing
end

function schedule_loop_precompile!(p::Process, lt = lifetime(p); loopfunc = loop)
    # Do not asynchronously precompile user-shaped process loops from the
    # constructor. Immediate `run` calls otherwise compile the same large loop
    # in the foreground while the background precompile is still active.
    #
    # How to write it: precompile the function the run's task calls with the tuple of its argument types, e.g.
    #     precompile(_run_process_task, (typeof(p), typeof(loopfunc), InteractiveSession{C, typeof(lt)}, typeof(getalgo(p)), LC, typeof(lt), Resuming{false}))
    # with LC the type of the `LoopContext` that `prepare_for_loop` builds (without inputs). Mark `_run_process_task`
    # `@noinline`, so the task's closure calls this compiled method instead of compiling the loop again inline.
    return p
end

function wait_loop_precompile!(p::Process, func, lc, lt, resume::Resuming; loopfunc = loop)
    # How to write it: if `schedule_loop_precompile!` compiles on a background task, wait for that task here, so the run
    # does not compile the same loop in the foreground at the same time.
    return nothing
end
