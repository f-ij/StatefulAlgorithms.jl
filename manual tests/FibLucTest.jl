include("FibLucDef.jl")

FibLuc = CompositeAlgorithm( (Fib, Luc), (1,1) )
p = Process(FibLuc, lifetime = 100000)
start(p)
benchmark(FibLuc, 1000000)
NaiveFibluc(1000000)