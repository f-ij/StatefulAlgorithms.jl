include("_env.jl")

mutable struct MutableTestAlgo <: ProcessAlgorithm
    value::Int
end

function StatefulAlgorithms.init(algo::MutableTestAlgo, _input)
    algo.value = 0
    return (;)
end

function StatefulAlgorithms.step!(algo::MutableTestAlgo, context)
    algo.value += 1
    return (;)
end
m = MutableTestAlgo(0)
m2 = MutableTestAlgo(0)
c = CompositeAlgorithm(m, m2)
p = InlineProcess(c, lifetime = 5)
@code_warntype run(p)