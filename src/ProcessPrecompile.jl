_is_generating_package_output() = ccall(:jl_generating_output, Cint, ()) != 0

@inline function precompile_loop!(loopfunc, p::Process, func, context, lt, inputs::NamedTuple = (;), resume::Resuming = Resuming{false}())
    precompile_loop!(typeof(loopfunc), typeof(p), typeof(func), typeof(context), typeof(lt), typeof(inputs), typeof(resume))
    return nothing
end

@inline precompile_loop!(p::Process, func, context, lt) = precompile_loop!(loop, p, func, context, lt)

function _callable_instance(::Type{F}) where {F}
    return isdefined(F, :instance) ? getfield(F, :instance) : nothing
end

function precompile_loop!(
    loopfunc_type::Type,
    process_type::Type,
    func_type::Type,
    context_type::Type,
    lifetime_type::Type,
    inputs_type::Type,
    resume_type::Type,
)
    loopfunc = _callable_instance(loopfunc_type)
    isnothing(loopfunc) && return nothing
    Base.precompile(loopfunc, (process_type, func_type, context_type, lifetime_type, inputs_type, resume_type, NonGenerated))
    return nothing
end

function _schedule_loop_precompile!(
    loopfunc_type::Type,
    process_type::Type,
    func_type::Type,
    context_type::Type,
    lifetime_type::Type,
    inputs_type::Type,
    resume_type::Type,
)
    if _is_generating_package_output()
        precompile_loop!(loopfunc_type, process_type, func_type, context_type, lifetime_type, inputs_type, resume_type)
    else
        Threads.@spawn precompile_loop!(loopfunc_type, process_type, func_type, context_type, lifetime_type, inputs_type, resume_type)
    end
    return nothing
end

function schedule_loop_precompile!(p::Process, lt = lifetime(p); loopfunc = loop)
    # Do not asynchronously precompile user-shaped process loops from the
    # constructor. Immediate `run` calls otherwise compile the same large loop
    # in the foreground while the background precompile is still active.
    return p
end

function wait_loop_precompile!(p::Process, func, context, lt, inputs::NamedTuple, resume::Resuming; loopfunc = loop)
    return nothing
end
