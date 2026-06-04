include("_env.jl")
# @ProcessAlgorithm function Fib(fiblist)
#     push!(fiblist, fiblist[end] + fiblist[end-1])
#     return (;)
# end
struct Fib <: ProcessAlgorithm end
struct Luc <: ProcessAlgorithm end

function StatefulAlgorithms.step!(::Fib, context::C) where C
    fiblist = context.fiblist
    push!(fiblist, fiblist[end] + fiblist[end-1])
    return (;)
end

function StatefulAlgorithms.init(::Fib, context::C) where C
    n_calls = num_calls(context)
    fiblist = Int[0, 1]
    processsizehint!(fiblist, context)
    return (;fiblist)
end

function StatefulAlgorithms.step!(::Luc, context::C) where C
    luclist = context.luclist
    push!(luclist, luclist[end] + luclist[end-1])
    return (;)
end

function StatefulAlgorithms.init(::Luc, context::C) where C
    luclist = Int[2, 1]
    processsizehint!(luclist,context)
    return (;luclist)
end


# const naive_luclist = Int[2, 1]
# const naive_fiblist = Int[0, 1]
using Statistics
function NaiveFibluc(num, trials = 100)

    times = Float64[]
    for i in 1:trials
        luclist = Int[2, 1]
        fiblist = Int[0, 1]

        sizehint!(fiblist, num+2)
        sizehint!(luclist, num+2)
        t1 = time_ns()
        for iteration in 1:num
            push!(fiblist, fiblist[end] + fiblist[end-1])
            push!(luclist, luclist[end] + luclist[end-1])
        end
        elapsed = (time_ns() - t1) / 1e9
        push!(times, elapsed)
    end
    return mean(times)
end