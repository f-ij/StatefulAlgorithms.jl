include("FibLucDef.jl")

r = Routine((Fib,Luc), (1000000, 1000000))
pr = Process(r, repeats = 1)
start(pr)
benchmark(r, 1)

