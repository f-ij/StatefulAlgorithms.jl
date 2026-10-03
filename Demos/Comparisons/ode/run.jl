# julia --project=Demos/Comparisons/ode Demos/Comparisons/ode/run.jl [lorenz|brusselator|robertson|all]
#
# Only the loop is timed: every variant builds its integrator, process or buffers first (untimed),
# then `go!` runs the loop. Variants are interleaved; the reported time is the minimum over rounds of
# the mean loop time of `reps` freshly set-up runs.
using Printf
include(joinpath(@__DIR__, "problems.jl"))
include(joinpath(@__DIR__, "dp5.jl"))
include(joinpath(@__DIR__, "variants.jl"))

relerr(u, ref) = norm(u .- ref) / norm(ref)

function loop_time(v::Variant, prob, rtol, atol, reps)
    total = 0.0
    for _ in 1:reps
        s = v.setup(prob, rtol, atol)
        GC.gc(false)
        t0 = time_ns(); v.go!(s); total += (time_ns() - t0) / 1e9
    end
    return total / reps
end

function compare(prob, variants, tols; reps, rounds = 7, baseline)
    println("\n", prob.name, ",  t in [0, ", prob.tend, "]")
    ref = reference(prob)
    for tol in tols
        for v in variants; v.go!(v.setup(prob, tol, tol)); end                  # compile
        results = [(s = v.setup(prob, tol, tol); v.go!(s); v.result(s)) for v in variants]
        best = fill(Inf, length(variants))
        for _ in 1:rounds, (k, v) in enumerate(variants)
            best[k] = min(best[k], loop_time(v, prob, tol, tol, reps))
        end
        base = best[findfirst(v -> startswith(v.name, baseline), variants)]
        @printf("  tolerance %.0e\n", tol)
        @printf("    %-42s %14s %22s %22s %10s\n", "variant", "loop, ms", "loop time / $(baseline)'s", "attempts (acc + rej)", "rel. error")
        for (k, v) in enumerate(variants)
            u, na, nr = results[k]
            @printf("    %-42s %14.4f %22.2f %14d + %-6d %10.1e\n", v.name, best[k] * 1e3, best[k] / base, na, nr, relerr(u, ref))
        end
    end
end

dp5_variants = [
    sciml_solve_variant("S1 SciML DP5, solve!()", DP5()),
    sciml_loop_variant("S5 SciML DP5, step! loop", DP5()),
    hand_variant("H  hand-written DP5 loop"),
    hand_untyped_variant("H0 hand-written, untyped state"),
    framework_variant("R  DP5 as @StepAlgorithm"),
    framework_variant("R2 DP5 as @StepAlgorithm, @inline", DP5AttemptInline),
    hosted_variant("W  SciML DP5 hosted in a step", DP5()),
]

which = get(ARGS, 1, "all")
which in ("lorenz", "all") && compare(lorenz(), dp5_variants, (1e-6, 1e-9, 1e-12); reps = 100, baseline = "H ")
which in ("brusselator", "all") && compare(brusselator(32), dp5_variants, (1e-6,); reps = 3, baseline = "H ")
if which in ("robertson", "all")
    stiff = [
        sciml_solve_variant("S3 SciML Rodas5P, solve!()", Rodas5P()),
        sciml_loop_variant("S6 SciML Rodas5P, step! loop", Rodas5P()),
        hosted_variant("W2 Rodas5P hosted in a step", Rodas5P()),
    ]
    compare(robertson(100.0), stiff, (1e-6, 1e-10); reps = 50, baseline = "S6")
end
