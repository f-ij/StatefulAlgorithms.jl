# julia --project=Demos/Comparisons/driven Demos/Comparisons/driven/run_modifiers.jl
# The same driven chain (sine force, checkpoints), now with modifiers that rewire internal variables:
# the damping inside the parameters, the integrator's tolerance, and impulses added to the state.
# Loop time only; subsets of the modifiers are chosen when the plan is built.
using Printf, LinearAlgebra
include(joinpath(@__DIR__, "scenario.jl")); include(joinpath(@__DIR__, "hand.jl"))
include(joinpath(@__DIR__, "framework.jl")); include(joinpath(@__DIR__, "sciml.jl")); include(joinpath(@__DIR__, "modifiers.jl"))

struct Impl; name::String; setup::Function; go!::Function; result::Function; end
function impls(mods)
    val(m) = Val(m in mods)
    [Impl("H  hand-written loop", () -> hand_setup(sine_force), s -> hand_mod_loop!(s, val(:kick), val(:ramp), val(:tol), val(:noise)), s -> (s.u, s.nacc, s.nrej, length(s.snaps))),
     Impl("P  StatefulAlgorithms", () -> modified_setup(mods), framework_go!, framework_result),
     Impl("S  SciML (callbacks)", () -> sciml_modified_setup(mods), sciml_go!, sciml_result)]
end
function loop_time(im::Impl, reps)
    total = 0.0
    for _ in 1:reps
        s = im.setup(); GC.gc(false)
        t0 = time_ns(); im.go!(s); total += (time_ns() - t0) / 1e9
    end
    return total / reps
end

println("Driven chain, sine force, checkpoint every ", CKPT_EVERY, " accepted steps, t in [0, ", TEND, "]. Loop time only.")
for mods in ((), (:ramp,), (:ramp, :tol), (:kick, :ramp, :tol), (:kick, :noise, :ramp, :tol))
    ims = impls(mods)
    println("\nmodifiers: ", isempty(mods) ? "none" : join(string.(mods), " + "))
    local results
    try
        for im in ims; s = im.setup(); im.go!(s); end
        results = map(im -> (s = im.setup(); im.go!(s); im.result(s)), ims)
    catch err
        println("  FAILED: ", sprint(showerror, err)); continue
    end
    best = fill(Inf, length(ims))
    for _ in 1:7, (k, im) in enumerate(ims); best[k] = min(best[k], loop_time(im, 5)); end
    uh = results[1][1]
    @printf("  %-24s %10s %22s %16s %14s %22s %20s\n", "implementation", "loop, ms", "attempts (acc + rej)", "checkpoints", "us / attempt", "loop time / H's time", "rel. diff of u(T) to H")
    for (k, im) in enumerate(ims)
        u, na, nr, ns = results[k]
        @printf("  %-24s %10.3f %14d + %-6d %16d %14.3f %22.2f %20.1e\n", im.name, best[k] * 1e3, na, nr, ns, best[k] / (na + nr) * 1e6, best[k] / best[1], norm(u .- uh) / norm(uh))
    end
end
