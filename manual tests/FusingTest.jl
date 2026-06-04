include("FibLucDef.jl")
import StatefulAlgorithms as ps
FLSimple = CompositeAlgorithm((Fib,Luc))
FibLuc = fuse(CompositeAlgorithm((Fib,Luc)))
