using StatefulAlgorithms, JET, UUIDs
const SA = StatefulAlgorithms
@StepAlgorithm function Counter(@managed(x = 0.0)); return (; x = x + 1.0); end
@StepAlgorithm function Tally(@managed(n = 0.0)); return (; n = n + 1.0); end
stable_unique(f, n) = IdentifiableAlgo(f; id = SA.SimpleId(UUID(UInt128(n))))
a = stable_unique(Counter(), 1); b = stable_unique(Counter(), 2)
plan = CompositeAlgorithm(a, b, Tally, (1, 1, 1))
rep = JET.report_opt(resolve, (typeof(plan),); target_modules = (StatefulAlgorithms,))
reports = JET.get_reports(rep)
println(length(reports), " reports; for each: the innermost frames (file:line  function) where it happens")
for (i, r) in enumerate(reports)
    i > 16 && break
    frames = r.vst
    kind = string(typeof(r).name.name)
    where_ = join([string(basename(string(f.file)), ":", f.line) for f in frames[max(1, end-2):end]], "  <-  ")
    msg = try sprint(JET.print_report_message, r) catch; "(message not printable)" end
    println(i, " ", kind, " | ", first(replace(msg, "\n" => " "), 150), " | ", where_)
end
