include("FibLucDef.jl")
import StatefulAlgorithms as ps

Fdup = Unique(Fib())
const cf = Fdup
Fdup2 = Unique(Fib)
Ldup = Unique(Luc)

Simple = CompositeAlgorithm(Fib)
pack = package(Simple)

Simple = CompositeAlgorithm(Fib, Fib(), Ldup)
Simple2 = CompositeAlgorithm(Fib, Fib(), Luc)
FibLuc = CompositeAlgorithm(Fib(), Fib, Luc)

C = Routine(Fib, Fib(), FibLuc, (10, 20, 30))

FFluc = CompositeAlgorithm(C, FibLuc, Fdup, Fib, Ldup, (1, 10, 5, 2, 1), Route(Fdup => Ldup, :fib => :luc), Route(Fib => Fdup, :fib => :fib, transform = x -> x + 1), Share(Fib, Ldup))
using BenchmarkTools
@benchmark CompositeAlgorithm(C, FibLuc, Fdup, Fib, Ldup, (1, 10, 5, 2, 1), Route(Fdup => Ldup, :fib => :luc), Route(Fib => Fdup, :fib => :fib, transform = x -> x + 1), Share(Fib, Ldup))
routes = FFluc.options
reg = ps.setup_registry(FFluc)
