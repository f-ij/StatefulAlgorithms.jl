#=
Building a `TimedProcess`: the plan and lifetime are prepared as for a `Process` (`_prepare_process`), then the struct
is made with a session for the lifetime's type.
=#

"""
    TimedProcess(func, Init(...), Override(...); interval, context, repeats, lifetime)

A process running one step of `func` every `interval` seconds once `run`. The plan is initialized (or given its
`context`) and the lifetime made from `repeats` or `lifetime` as for a `Process` (`_prepare_process`).
"""
function TimedProcess(func::Func, inputs_overrides::Vararg{Any,N}; interval::Real, kwargs...) where {Func,N}
    algo, lifetime, _ = _prepare_process(parse_plan(func), inputs_overrides...; kwargs...)
    C = typeof(loop_cursor(getplan(algo), Val(true)))
    session = InteractiveSession{C, typeof(lifetime)}()
    tp = TimedProcess{typeof(algo), C}(algo, lifetime, nothing, nothing, Float64(interval), nothing, ReentrantLock(), nothing, session)
    precompile_interface(tp)   # src/PrecompileInterface.jl
    return tp
end
