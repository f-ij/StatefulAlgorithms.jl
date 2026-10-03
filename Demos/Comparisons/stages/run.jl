# julia --project=Demos/Comparisons/stages Demos/Comparisons/stages/run.jl
# Loop time of the multi-stage experiment summed over the sweep of maximum fields; setup (building the plan, the integrator,
# the buffers) is not timed.
using Printf, LinearAlgebra
include(joinpath(@__DIR__, "scenario.jl")); include(joinpath(@__DIR__, "hand.jl"))
include(joinpath(@__DIR__, "framework.jl")); include(joinpath(@__DIR__, "sciml.jl"))

struct Impl; name::String; setup::Function; go!::Function; result::Function; end
impls = [Impl("H  hand-written monolith", hand_setup, hand_go!, hand_result),
         Impl("P  StatefulAlgorithms (stages, core, protocols)", framework_setup, framework_go!, framework_result),
         Impl("S  SciML (fixed step, callbacks)", sciml_setup, sciml_go!, sciml_result)]

function sweep_time(im::Impl)
    total = 0.0
    for Emax in EMAXES
        s = im.setup(Emax); GC.gc(false)
        t0 = time_ns(); im.go!(s); total += (time_ns() - t0) / 1e9
    end
    return total
end

for im in impls; s = im.setup(EMAXES[1]); im.go!(s); end                      # compile
println("Multi-stage hysteresis experiment: ", length(EMAXES), " maximum fields ", EMAXES, ", stages of ", (N1, N2, N3, N4),
        " steps (", NTOTAL, " per run), dt ", DT, ", polarization logged every step and (E, P) every ", KLOG, " steps. Loop time only.\n")
# correctness against the hand-written monolith
refs = Dict(Emax => (s = hand_setup(Emax); hand_go!(s); s) for Emax in EMAXES)
for im in impls[2:end]
    ident = true; maxrel = 0.0; trace_same = true; pairs_same = true; ntrace = 0; npairs = 0
    for Emax in EMAXES
        s = im.setup(Emax); im.go!(s); u, t, trace, pairs = im.result(s)
        r = refs[Emax]
        ident &= (u == r.u); trace_same &= (trace == r.trace); pairs_same &= (pairs == r.pairs)
        ntrace = length(trace); npairs = length(pairs)
        maxrel = max(maxrel, norm(u .- r.u) / norm(r.u))
    end
    @printf("%-52s final states identical: %-5s (largest relative difference %.1e); logged polarization trace identical: %-5s (%d entries); (E, P) pairs identical: %-5s (%d)\n",
            im.name, ident, maxrel, trace_same, ntrace, pairs_same, npairs)
end
best = fill(Inf, length(impls))
for _ in 1:7, (k, im) in enumerate(impls); best[k] = min(best[k], sweep_time(im)); end
steps = NTOTAL * length(EMAXES)
@printf("\n%-52s %12s %16s %24s\n", "implementation", "loop, ms", "ns / step", "loop time / monolith's")
for (k, im) in enumerate(impls)
    @printf("%-52s %12.2f %16.1f %24.2f\n", im.name, best[k] * 1e3, best[k] / steps * 1e9, best[k] / best[1])
end
