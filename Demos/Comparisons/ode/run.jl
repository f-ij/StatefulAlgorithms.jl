# julia --project=Demos/Comparisons/ode Demos/Comparisons/ode/run.jl [lorenz|brusselator|robertson|all]
using Printf
include(joinpath(@__DIR__, "problems.jl"))
include(joinpath(@__DIR__, "dp5.jl"))
include(joinpath(@__DIR__, "variants.jl"))

relerr(u, ref) = norm(u .- ref) / norm(ref)

"""Time one variant (H = the hand-written loop is the baseline of the "time / H's time" column): minimum over `rounds` of the mean of `reps` solves (variants interleaved by the caller)."""
function time_solves(f, reps)
    t0 = time_ns()
    for _ in 1:reps; f(); end
    return (time_ns() - t0) / 1e9 / reps
end

function compare(prob, variants, tols; reps, rounds = 7)
    println("\n", prob.name, ",  t in [0, ", prob.tend, "]")
    ref = reference(prob)
    for tol in tols
        fs = [(name, () -> f(prob, tol, tol)) for (name, f) in variants]
        for (_, f) in fs; f(); end                                   # compile
        results = [f() for (_, f) in fs]
        best = [Inf for _ in fs]
        for _ in 1:rounds, (k, (_, f)) in enumerate(fs)
            GC.gc(false); best[k] = min(best[k], time_solves(f, reps))
        end
        @printf("  tolerance %.0e\n", tol)
        @printf("    %-44s %13s %20s %22s %10s\n", "variant", "ms per solve", "time / H's time", "attempts (acc + rej)", "rel. error")
        base = best[findfirst(v -> startswith(first(v), "H"), variants)]
        for (k, (name, _)) in enumerate(variants)
            u, na, nr = results[k]
            @printf("    %-44s %13.3f %20.2f %14d + %-6d %10.1e\n",
                    name, best[k] * 1e3, best[k] / base, na, nr, relerr(u, ref))
        end
    end
end

dp5_variants = [
    "S1 SciML DP5 (same method)"       => (p, r, a) -> sciml_solve(p, DP5(), r, a),
    "S2 SciML Tsit5"                   => (p, r, a) -> sciml_solve(p, Tsit5(), r, a),
    "H  hand-written DP5 loop"         => dp5_hand,
    "H0 hand-written, no function barrier" => dp5_hand_nobarrier,
    "R  DP5 as @StepAlgorithm"         => dp5_framework,
    "W  SciML DP5 hosted in a step"    => (p, r, a) -> sciml_hosted(p, DP5(), r, a),
]

which = get(ARGS, 1, "all")
which in ("lorenz", "all") && compare(lorenz(), dp5_variants, (1e-6, 1e-9); reps = 200)
which in ("brusselator", "all") && compare(brusselator(32), dp5_variants, (1e-6,); reps = 3)
if which in ("robertson", "all")
    stiff = [
        "S3 SciML Rodas5P (implicit, stiff)"      => (p, r, a) -> sciml_solve(p, Rodas5P(), r, a),
        "W2 Rodas5P hosted in a step"             => (p, r, a) -> sciml_hosted(p, Rodas5P(), r, a),
        "H  hand-written DP5 loop (explicit)"     => dp5_hand,
        "R  DP5 as @StepAlgorithm (explicit)"     => dp5_framework,
    ]
    compare(robertson(100.0), stiff, (1e-6,); reps = 3)
end
