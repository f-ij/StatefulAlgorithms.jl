using StatefulAlgorithms, UUIDs, JET
const SA = StatefulAlgorithms
@StepAlgorithm function Counter(@managed(x = 0.0)); return (; x = x + 1.0); end
@StepAlgorithm function Tally(@managed(n = 0.0)); return (; n = n + 1.0); end
@StepAlgorithm function Reader(x, @managed(seen = 0.0)); return (; seen = x); end
su(f, n) = IdentifiableAlgo(f; id = SA.SimpleId(UUID(UInt128(n))))
a = su(Counter(), 1); b = su(Counter(), 2)
shapes = [
  ("plain (two Unique copies + Tally)",        CompositeAlgorithm(a, b, Tally, (1, 1, 1))),
  ("with a Route from b to Reader",            CompositeAlgorithm(a, b, Reader, (1, 1, 1), Route(b => Reader, :x))),
  ("with a Share",                             CompositeAlgorithm(a, b, Tally, (1, 1, 1), Share(a, b))),
  ("nested CompositeAlgorithm",                CompositeAlgorithm(CompositeAlgorithm(a, Tally, (1, 2)), b, (1, 1))),
  ("Routine",                                  Routine(a, b, Tally, (2, 1, 3))),
  ("Routine with a Route",                     Routine(a, b, Reader, (2, 1, 3), Route(b => Reader, :x))),
  ("composite of a routine and an algorithm",  CompositeAlgorithm(Routine(a, Tally, (2, 1)), b, (1, 1))),
]
short(x) = (s = string(x); length(s) > 78 ? s[1:78] * "..." : s)
println(rpad("plan shape", 42), rpad("resolve infers", 14), "JET reports (runtime dispatch etc.)")
for (name, plan) in shapes
    T = Base.return_types(resolve, (typeof(plan),))[1]
    nrep = try length(JET.get_reports(JET.report_opt(resolve, (typeof(plan),); target_modules = (StatefulAlgorithms,)))) catch e; -1 end
    println(rpad(name, 42), rpad(isconcretetype(T) ? "concrete" : "NOT concrete", 14), nrep)
end
