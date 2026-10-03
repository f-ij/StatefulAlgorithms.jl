using StatefulAlgorithms, JET, UUIDs
const SA = StatefulAlgorithms
@StepAlgorithm function Counter(@managed(x = 0.0)); return (; x = x + 1.0); end
@StepAlgorithm function Tally(@managed(n = 0.0)); return (; n = n + 1.0); end
stable_unique(f, n) = IdentifiableAlgo(f; id = SA.SimpleId(UUID(UInt128(n))))
a = stable_unique(Counter(), 1); b = stable_unique(Counter(), 2)
plan = CompositeAlgorithm(a, b, Tally, (1, 1, 1))
rep = JET.report_opt(resolve, (typeof(plan),); target_modules = (StatefulAlgorithms,))
reports = JET.get_reports(rep)
function show_stack(r, n)
    println("=== report ", n)
    for f in r.vst
        sig = try string(f.sig) catch; "?" end
        println("  ", basename(string(f.file)), ":", f.line, "   ", first(replace(sig, "StatefulAlgorithms." => ""), 150))
    end
end
for n in (1, 5, 7, 10, 11)
    n <= length(reports) && show_stack(reports[n], n)
end
