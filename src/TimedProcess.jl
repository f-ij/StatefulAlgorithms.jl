mutable struct TimedProcess{TD, C} <: AbstractProcess
    timer::Union{Timer, Nothing}
    algo::TD
    callback::Function
    context::C
    paused::Bool
end

function TimedProcess(@nospecialize(func); kwargs...)
    algo = func isa LoopSpec ? func : normalize_process_algo(func)
    algo isa LoopSpec && (algo = resolve(algo))
    return _new_timed_process(strip_keymap(algo); kwargs...)
end

function _new_timed_process(algo::F; lifetime = Indefinite(), interval::Real = 0., context = nothing) where F
    context = strip_keymap(context)
    algo = isnothing(context) ? _init_plan(algo) : _with_lifecycle(resolve(algo), context, (), ())
    prepared_context = getpersistentcontext(algo)

    callback = let context = prepared_context
        timer -> @inline step!(algo, context)
    end

    return TimedProcess(nothing, algo, callback, prepared_context, true)
end

function init!(tp::TimedProcess)
    tp.algo = _init_plan(tp.algo)
    tp.context = getpersistentcontext(tp.algo)
    tp.callback = let context = tp.context
        timer -> @inline step!(tp.algo, context)
    end
    return tp
end

function run(tp::TimedProcess)
    if !tp.paused
        init!(tp)
    end
    if tp.timer === nothing
        tp.timer = Timer(tp.callback, 0; interval = tp.timer.interval)
    end
    return tp
end

function pause(tp::TimedProcess)
    if tp.timer[] !== nothing
        close(tp.timer[])
        tp.timer[] = nothing
    end
    tp.paused = true
    return tp
end

function Base.close(tp::TimedProcess)
    if tp.timer[] !== nothing
        close(tp.timer[])
        tp.timer[] = nothing
    end
    return tp
end

