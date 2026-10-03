# Splits hosted-minus-plain-SciML into a fixed cost per run and a cost per step (varying the step count).
using Printf
include(joinpath(@__DIR__, "overhead.jl"))   # reuses its definitions; its own table prints first

println("\n--- fixed vs per-step ---")
@printf("%-12s %10s %18s %18s %14s %16s\n", "tolerance", "attempts", "S5 (microseconds)", "W (microseconds)", "W - S5 (us)", "(W - S5) / attempts (ns)")
rows = Tuple{Int,Float64}[]
for tol in (1e-6, 1e-9, 1e-12)
    na, nr = let (_, a, b) = sciml_barrier(prob, alg, tol, tol); (a, b); end
    f5 = () -> sciml_barrier(prob, alg, tol, tol); fw = () -> sciml_hosted(prob, alg, tol, tol)
    f5(); fw()
    reps = max(5, round(Int, 3000 / (na + nr)))
    b5 = Inf; bw = Inf
    for _ in 1:9
        GC.gc(false); t0 = time_ns(); for _ in 1:reps; f5(); end; b5 = min(b5, (time_ns() - t0) / reps / 1e3)
        GC.gc(false); t0 = time_ns(); for _ in 1:reps; fw(); end; bw = min(bw, (time_ns() - t0) / reps / 1e3)
    end
    push!(rows, (na + nr, bw - b5))
    @printf("%-12.0e %10d %18.2f %18.2f %14.2f %16.1f\n", tol, na + nr, b5, bw, bw - b5, (bw - b5) / (na + nr) * 1e3)
end
(n1, d1), (n2, d2) = rows[1], rows[3]
@printf("\nfit  W - S5 = fixed + per_attempt * attempts:  per attempt %.1f ns,  fixed %.2f microseconds\n",
        (d2 - d1) / (n2 - n1) * 1e3, d1 - (d2 - d1) / (n2 - n1) * n1)

# construction vs run for the trivial process
function ctor_vs_run()
    ctor = Inf; runt = Inf
    for _ in 1:9
        GC.gc(false); t0 = time_ns(); for _ in 1:2000; InlineProcess(Noop(); repeats = 1); end; ctor = min(ctor, (time_ns() - t0) / 2000 / 1e3)
        ip = InlineProcess(Noop(); repeats = 1)
        GC.gc(false); t0 = time_ns(); for _ in 1:2000; run(ip); end; runt = min(runt, (time_ns() - t0) / 2000 / 1e3)
    end
    return ctor, runt
end
ctor, runt = ctor_vs_run()
@printf("trivial process: construction %.2f microseconds, run %.2f microseconds\n", ctor, runt)
