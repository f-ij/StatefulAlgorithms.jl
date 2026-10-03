# Where does the hosted version's extra time come from? Splits it into SciML's own init+step! loop,
# the framework's fixed per-run cost, and the per-step cost of the lifetime check.
using Printf
include(joinpath(@__DIR__, "problems.jl"))
include(joinpath(@__DIR__, "dp5.jl"))
include(joinpath(@__DIR__, "variants.jl"))

prob = lorenz(); tol = 1e-6; alg = DP5()

# SciML alone, driven by a plain loop: the right baseline for "hosted in a step"
function sciml_initstep(prob, alg, rtol, atol)
    integ = SciMLBase.init(odeprob(prob), alg; reltol = rtol, abstol = atol, dt = prob.dt0,
                           save_everystep = false, save_start = false, controller = OrdinaryDiffEqCore.IController())
    while integ.t < prob.tend
        SciMLBase.step!(integ)
    end
    return (copy(integ.u), integ.stats.naccept, integ.stats.nreject)
end

sciml_barrier = sciml_stepped

# hosted, but stopped after a fixed number of steps instead of Until(t >= tend)
function hosted_repeat(prob, alg, rtol, atol, n)
    algo = SciMLHost()
    ip = InlineProcess(algo, Init(algo; prob, alg, rtol, atol); repeats = n)
    run(ip)
    return context(ip)[algo].integ
end

# the framework's fixed cost: build and run a process that does one trivial step
@StepAlgorithm function Noop(@managed(x = 0.0))
    return (; x = x + 1.0)
end
function trivial_process()
    ip = InlineProcess(Noop(); repeats = 1); run(ip); return context(ip)
end

nsteps = let (_, na, nr) = sciml_initstep(prob, alg, tol, tol); na + nr; end
variants = [
    "S  SciML solve()"                          => () -> sciml_solve(prob, alg, tol, tol),
    "S4 SciML init + step! loop (no framework)" => () -> sciml_initstep(prob, alg, tol, tol),
    "S5 SciML init + step! loop, function barrier" => () -> sciml_barrier(prob, alg, tol, tol),
    "W  hosted, Until(t >= tend)"               => () -> sciml_hosted(prob, alg, tol, tol),
    "W' hosted, Repeat($nsteps)"                => () -> hosted_repeat(prob, alg, tol, tol, nsteps),
    "T  trivial InlineProcess (1 step)"         => trivial_process,
]
for (_, f) in variants; f(); end
reps = 300
best = fill(Inf, length(variants))
for _ in 1:9, (k, (_, f)) in enumerate(variants)
    GC.gc(false); t0 = time_ns(); for _ in 1:reps; f(); end
    best[k] = min(best[k], (time_ns() - t0) / reps / 1e3)
end
base = best[3]
@printf("%-44s %16s %24s\n", "variant (Lorenz, tolerance 1e-6)", "microseconds", "time / S5's time")
for (k, (n, _)) in enumerate(variants)
    @printf("%-44s %16.2f %24.2f\n", n, best[k], best[k] / base)
end
@printf("\nhosted minus S5: %.2f microseconds;  trivial process (fixed cost): %.2f microseconds\n", best[4] - best[3], best[6])
