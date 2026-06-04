include("_env.jl")
include("FibLucDef.jl")
import StatefulAlgorithms as ps

Fdup = Unique(Fib())
Fdup2 = Unique(Fib)
Ldup = Unique(Luc)


FibLuc = CompositeAlgorithm( Fib(), Fib, Luc, (1,1,2) , 
    Route(Fib() => Luc, :fiblist),
    Route(Fib => Luc, :fiblist),
    Route(Luc => Fib, :luclist)
)



C = Routine( Fib, Fib(), FibLuc, (10,20,30))


FFluc = CompositeAlgorithm( FibLuc, Fdup, Fib, Ldup, (10,5,2,1) )
f = resolve(FFluc)
c = ProcessContext(f)
reg = getregistry(f)
# p = Process(FFluc)
# run(p)
# sleep(0.2)
# quit(p)
# println(p.context)
