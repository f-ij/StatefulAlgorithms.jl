using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using StatefulAlgorithms

struct Fib <: ProcessAlgorithm end

function (::Fib)(args)
    (;fiblist) = args
    push!(fiblist, fiblist[end] + fiblist[end-1])
end

function Fib(args)
    (;fiblist) = args
    push!(fiblist, fiblist[end] + fiblist[end-1])
end

function StatefulAlgorithms.init(::Fib, args)
    println("Preparing with type")
    return (;fiblist = [0, 1])
end

function StatefulAlgorithms.init(::typeof(Fib), args)
    println("Preparing with typeof")
    return (;fiblist = [0, 1])
end

struct Luc <: ProcessAlgorithm end

function (::Luc)(args)
    (;luclist) = args
    push!(luclist, luclist[end] + luclist[end-1])
end

function Luc(args)
    (;luclist) = args
    push!(luclist, luclist[end] + luclist[end-1])
end


function StatefulAlgorithms.init(::Luc, args)
    println("Preparing with type")
    return (;luclist = [2, 1])
end
function StatefulAlgorithms.init(::typeof(Luc), args)
    println("Preparing with typeof")
    return (;luclist = [2, 1])
end

FibLucComp = CompositeAlgorithm( (Fib, Luc), (1,2) )

###
struct FibLuc end

StatefulAlgorithms.init(::Type{FibLuc}, args) = (;fiblist = [0, 1], luclist = [2, 1])

function FibLuc(args)
    (;process) = args
    @inline Fib(args)
    if loopidx(process) % 2 == 0
        @inline Luc(args)
    end
end

struct FibLucTrig{Intervals} end

function StatefulAlgorithms.init(::Type{FibLucTrig{Intervals}}, args) where Intervals
    (;lifetime) = args
    rpts = StatefulAlgorithms.repeats(lifetime)
    triggers = ((StatefulAlgorithms.InitTriggerList(interval) for interval in Intervals)...,)
    for i in 1:rpts
        for (i_idx, interval) in enumerate(Intervals)
            if i % interval == 0
                push!(triggers[i_idx].triggers, i)
            end
        end
    end
    triggers = StatefulAlgorithms.CompositeTriggers(triggers)
    return (;fiblist = [0, 1], luclist = [2, 1], triggers)
end

function FibLucTrig{(1,2)}(args)
    (;process, triggers) = args
    Fib(args)
    StatefulAlgorithms.skiplist!(triggers)
    if StatefulAlgorithms.shouldtrigger(triggers, loopidx(process))
        Luc(args)
        StatefulAlgorithms.inc!(triggers)
    end
    StatefulAlgorithms.skiplist!(triggers)
end

benchmark(FibLucComp, 1000000)
benchmark(FibLuc, 1000000)
# benchmark(FibLucTrig{(1,2)}, 1000000)

# benchmark(FibLucComp, 1000000, loopfunction = unrollloop)
# benchmark(FibLucComp, 1000000, loopfunction = StatefulAlgorithms.typeloop, progress = true)


# p, context = ex_p_and_context(FibLucComp, 1000000, loopfunction = unrollloop)
# (;lifetime) = args

# import StatefulAlgorithms: _comp_dispatch, gethead, gettail, get_intervals, headval, get_funcs, typeheadval, typetail
# @code_warntype StatefulAlgorithms.comp_dispatch(FibLucComp, args)
# const funcs = get_funcs(FibLucComp)
# const intervals = get_intervals(FibLucComp)
# @code_warntype StatefulAlgorithms._comp_dispatch(gethead(funcs), typeheadval(intervals), gettail(funcs), typetail(intervals), args)

# @code_warntype StatefulAlgorithms.unroll_step(FibLucComp, args)

p1 = Process(FibLuc; lifetime = 1000000)
start(p1)
runtime_ns(p1)

const outerargs = (;fiblist = [0, 1], luclist = [2, 1])
function testloop(args)
    loopidx = 1
    modtracker = 1
    init_time = time_ns()
    for _ in 1:1000000
        push!(args.fiblist, args.fiblist[end] + args.fiblist[end-1])
        # if loopidx % 2 == 0
        if modtracker == 2
            push!(args.luclist, args.luclist[end] + args.luclist[end-1])
        end
        
        loopidx += 2
    end
    runtime_ns = Int(time_ns() - init_time)
    return runtime_ns
end

function test_testloop()
    runtimes = []
    for _ in 1:100
        outerargs = (;fiblist = [0, 1], luclist = [2, 1])
        sizehint!(outerargs.fiblist, 1000002)
        sizehint!(outerargs.luclist, 500002)
        push!(runtimes, fetch(Threads.@spawn testloop(outerargs)))
    end
    runtimes ./= 1e9
    return sum(runtimes) / 100
end


test_testloop()
