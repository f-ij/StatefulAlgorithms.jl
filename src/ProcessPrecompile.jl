_is_generating_package_output() = ccall(:jl_generating_output, Cint, ()) != 0

@inline function precompile_loop!(loopfunc, p::Process{F, C}, func, context, lt, inputs::NamedTuple = (;), resume::Resuming = Resuming{false}()) where {F, C}
    # The loop runs on the session of a run with this lifetime (`create_session`), not on the process.
    precompile_loop!(typeof(loopfunc), InteractiveSession{C, typeof(lt)}, typeof(func), typeof(context), typeof(lt), typeof(inputs), typeof(resume))
    return nothing
end

@inline precompile_loop!(p::Process, func, context, lt) = precompile_loop!(loop, p, func, context, lt)

function _callable_instance(::Type{F}) where {F}
    return isdefined(F, :instance) ? getfield(F, :instance) : nothing
end

function precompile_loop!(
    loopfunc_type::Type,
    session_type::Type,
    func_type::Type,
    context_type::Type,
    lifetime_type::Type,
    inputs_type::Type,
    resume_type::Type,
)
    loopfunc = _callable_instance(loopfunc_type)
    isnothing(loopfunc) && return nothing
    Base.precompile(loopfunc, (session_type, func_type, context_type, lifetime_type, inputs_type, resume_type, NonGenerated))
    return nothing
end

function _schedule_loop_precompile!(
    loopfunc_type::Type,
    session_type::Type,
    func_type::Type,
    context_type::Type,
    lifetime_type::Type,
    inputs_type::Type,
    resume_type::Type,
)
    if _is_generating_package_output()
        precompile_loop!(loopfunc_type, session_type, func_type, context_type, lifetime_type, inputs_type, resume_type)
    else
        Threads.@spawn precompile_loop!(loopfunc_type, session_type, func_type, context_type, lifetime_type, inputs_type, resume_type)
    end
    return nothing
end

function schedule_loop_precompile!(p::Process, lt = lifetime(p); loopfunc = loop)
    # Do not asynchronously precompile user-shaped process loops from the
    # constructor. Immediate `run` calls otherwise compile the same large loop
    # in the foreground while the background precompile is still active.
    return p
end

"""
    _precompile_process!(p::Process)

Compiles what a first run calls with `p`, at construction: `run(p)`, the run's start with the process's own lifetime
(the run's session, `create_session`), and the task's body for a new run (`ProcessTaskBody`: the loop's contexts,
the run's end). `pause`, `close` and a resumed run compile when first used (16 ms together, measured). These are typed on the
process, whose type has the plan's `UniqueKeyMap`, so they are compiled for every set of `Unique` handles; the loop
itself is not (its arguments have no map) and is compiled once per plan.
"""
function _precompile_process!(p::P) where {P<:Process}
    precompile(run, (P,))
    session = getsession(p); lt = lifetime(p)
    S = InteractiveSession{typeof(session).parameters[1], typeof(lt)}
    Ctx = typeof(_context(p))
    # `run(p)` reads the lifetime from a field of abstract type, so its call into `_makeloop!` is dynamic: compiled here
    # with the process's own lifetime (keywords as `makeloop!` passes them).
    precompile(Core.kwcall, (NamedTuple{(:threaded, :loopfunc), Tuple{Bool, typeof(loop)}}, typeof(_makeloop!), P, NamedTuple{(), Tuple{}}, typeof(lt), Ctx))
    precompile(Tuple{ProcessTaskBody{P, typeof(loop), S, typeof(getalgo(p)), Ctx, typeof(lt), NamedTuple{(), Tuple{}}, Resuming{false}}})
    return nothing
end

function wait_loop_precompile!(p::Process, func, context, lt, inputs::NamedTuple, resume::Resuming; loopfunc = loop)
    return nothing
end
