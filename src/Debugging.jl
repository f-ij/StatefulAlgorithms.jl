define_processdebug_task(@specialize(p), @specialize(func), @specialize(context), @specialize(lifetime)) = @task mainloop_warntype(p, func, context, lifetime)

function process_warntype(p)
    func = getalgo(p)
    context = getcontextð(p)
    lifetime = getlifetime(p)
    mainloop_warntype(p, func, context, lifetime)
end
export process_warntype
# import InteractiveUtils: @code_warntype

function mainloop_warntype(@specialize(p), @specialize(func), @specialize(context), ::Lifetime)
    Base.code_typed(func, Tuple{typeof(context)}; optimize=true)
end

function get_example_process(func, rt; loopfunction = nothing)
    p = Process(func; repeats = rt)
    preparedata!(p)
    return p
end

function ex_p_and_context(func, rt; loopfunction = nothing)
    p = get_example_process(func, rt; loopfunction)
    context = getcontext(p)
    return p, context
end
export get_example_process, ex_p_and_context
