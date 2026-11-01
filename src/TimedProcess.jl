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
    return _new_timed_process(algo; kwargs...)
end

# The process keeps its plan and context with the plan's `UniqueKeyMap` in their registry (`with_keymap`); init and the
# step each timer tick get them without it (`strip_keymap`), as a `Process`'s loop does.
function _new_timed_process(@nospecialize(algo); lifetime = Indefinite(), interval::Real = 0., context = nothing)
    keymap = getkeymap(algo)
    loop_algo, context = strip_keymap(algo), strip_keymap(context)
    loop_algo = isnothing(context) ? _init_plan(loop_algo) : _with_lifecycle(resolve(loop_algo), context, (), ())
    prepared_context = getpersistentcontext(loop_algo)
    return TimedProcess(nothing, with_keymap(loop_algo, keymap), _timed_step_callback(loop_algo, prepared_context),
        with_keymap(prepared_context, keymap), true)
end

# What each timer tick runs: one step of the plan on its context, both without the map.
_timed_step_callback(loop_algo, context) = timer -> @inline step!(loop_algo, context)

function init!(tp::TimedProcess)
    keymap = getkeymap(tp.algo)
    loop_algo = _init_plan(strip_keymap(tp.algo))
    prepared_context = getpersistentcontext(loop_algo)
    tp.algo = with_keymap(loop_algo, keymap)
    tp.context = with_keymap(prepared_context, keymap)
    tp.callback = _timed_step_callback(loop_algo, prepared_context)
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

