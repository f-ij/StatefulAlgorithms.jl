include("_env.jl")

funcs = RunFuncs(sqrt, x -> x^2, x -> x^3, :state)
struct StateProvider <: ProcessState end
function StatefulAlgorithms.init(::StateProvider, context)
    return (;state = 2)
end

c = CompositeAlgorithm( (funcs,), (1,), StateProvider, Route(StateProvider, funcs, :state))
p= Process(c, lifetime = 1)
run(p)

