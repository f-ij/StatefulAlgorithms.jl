using StatefulAlgorithms, JET, UUIDs
const SA = StatefulAlgorithms
@StepAlgorithm function Counter(@managed(x = 0.0)); return (; x = x + 1.0); end
@StepAlgorithm function Tally(@managed(n = 0.0)); return (; n = n + 1.0); end
stable_unique(f, n) = IdentifiableAlgo(f; id = SA.SimpleId(UUID(UInt128(n))))
a = stable_unique(Counter(), 1); b = stable_unique(Counter(), 2)
plan = CompositeAlgorithm(a, b, Tally, (1, 1, 1))
println("inferred: ", Base.return_types(resolve, (typeof(plan),))[1])
rep = JET.report_opt(resolve, (typeof(plan),); target_modules = (StatefulAlgorithms,))
reports = JET.get_reports(rep)
println(length(reports), " reports")
for (i, r) in enumerate(reports)
    println("--- ", i, ": ", sprint(JET.print_report, r)[1:min(end, 700)])
    i >= 12 && break
end
