mutable struct TimedProcess{TD, C} <: AbstractProcess
    timer::Union{Timer, Nothing}
    algo::TD
    callback::Function
    context::C
    paused::Bool
end

function TimedProcess(func::F; lifetime = Indefinite(), interval::Real = 0., context = nothing) where F
    algo = isnothing(context) ? init(normalize_process_algo(func)) : _with_lifecycle(resolve(normalize_process_algo(func)), context, (), ())
    prepared_context = getstoredcontext(algo)

    callback = let context = prepared_context
        timer -> @inline step!(algo, context)
    end

    return TimedProcess(nothing, algo, callback, prepared_context, true)
end

function init!(tp::TimedProcess)
    tp.algo = init(tp.algo)
    tp.context = getstoredcontext(tp.algo)
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

