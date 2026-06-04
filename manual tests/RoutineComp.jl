include("FibLucDef.jl")

FibLuc = CompositeAlgorithm((Fib, Luc), (1,2))
FibLucRoutine = Routine((FibLuc, FibLuc), (100000,1000))
FLR = FibLucRoutine

pr = Process(FibLucRoutine, lifetime = 1)
start(pr)
# benchmark(FibLucRoutine, 1)