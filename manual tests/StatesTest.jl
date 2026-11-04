include("_env.jl")
import StatefulAlgorithms as ps

struct SomeState
    a::Int
end

inputstruct = SomeState(1)
logger = Logger(:a, Int)
c = CompositeAlgorithm(logger, DestructureInput(), Route(DestructureInput() => logger, :a => :value))
p = Process(c, repeats = 10, InitArgs(DestructureInput(), structure = inputstruct))


pack = package(c)

pp = Process(pack, repeats = 10, InitArgs(pack, structure = inputstruct))
run(pp)
