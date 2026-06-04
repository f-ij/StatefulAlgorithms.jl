include("FibLucDef.jl")
import StatefulAlgorithms as ps

FibLuc = CompositeAlgorithm( Fib, Luc, (1,1) )

Pack = ps.Package(FibLuc, "FLPack")
p = InlineProcess(Pack, lifetime = 100000)
# run(p)

# benchmark(Pack, 100000, 100; print_outer = true)
