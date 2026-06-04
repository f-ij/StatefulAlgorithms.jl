struct StartCloseListener{F}
    f::F
    procAbstractProcess
    weak::Bool
    type::Symbol
    function StartCloseListener(f, process, type, weak = false)
        sl = new{typeof(f)}(f, process, weak)
        weak && finalizer(off, sl)
        return sl
    end
end

StartListener(f, process) = StartCloseListener(f, process, :start)
CloseListener(f, process) = StartCloseListener(f, process, :close)

function _exec_listeners(head, fs)
    if isnothing(fs)
        return
    end
    head()
    _exec_listeners(gethead(fs), gettail(fs))
end


struct RuntimeListeners{ST, CT}
    start::ST
    close::CT
end

start(::Nothing) = nothing
start(rl::RuntimeListeners) = _exec_listeners(gethead(rl.start), gettail(rl.start))
Base.close(rl::RuntimeListeners) = _exec_listeners(gethead(rl.close), gettail(rl.close))


RuntimeListeners() = RuntimeListeners((), ())

function on(f, ::typeof(start), procAbstractProcess)
    sl = StartListener(f, process)
    runtimelisteners = process.rl
    newstart = (f, runtimelisteners.start...)
    process.rl = RuntimeListeners(newstart, runtimelisteners.close)
    return sl
end

function on(f, ::typeof(close), procAbstractProcess)
    sl = CloseListener(f, process)
    runtimelisteners = process.rl
    newclose = (f, runtimelisteners.close...)
    process.rl = RuntimeListeners(runtimelisteners.start, newclose)
    return sl
end

function off(sl::StartCloseListener)
    process = sl.process
    runtimelisteners = process.rl
    type = sl.type
    newstarts = runtimelisteners.start
    newcloses = runtimelisteners.close
    if type == :start
        newstarts = filter(x -> x != sl, newstarts)
    else
        newcloses = filter(x -> x != sl, newcloses)
    end

    process.rl = RuntimeListeners(newstarts, newcloses)
end