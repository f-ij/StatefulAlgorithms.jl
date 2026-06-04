include("_env.jl")
include("FibLucDef.jl")

comp = CompositeAlgorithm( Fib, Luc, (1,1) )
emptycontext = ProcessContext(comp)

p = Process(comp, lifetime = 100000)
comp = taskdata(p).func

@code_warntype initcontext(comp, emptycontext)


withglobals = StatefulAlgorithms._merge_into_globals(emptycontext, (;lifetime = StatefulAlgorithms.Indefinite(), algo = comp))
# @code_warntype initcontext(comp, emptycontext; lifetime = StatefulAlgorithms.Indefinite())
@code_warntype init(comp, withglobals)
c1 = comp[1]
@code_warntype init(c1, withglobals)