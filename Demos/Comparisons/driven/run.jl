# julia --project=Demos/Comparisons/driven Demos/Comparisons/driven/run.jl
#
# One run per force shape. Only the loop is timed: integrators, processes and buffers are built first (untimed),
# then the loop runs. Implementations are interleaved; the time is the minimum over rounds.
using Printf, LinearAlgebra
include(joinpath(@__DIR__, "scenario.jl")); include(joinpath(@__DIR__, "hand.jl"))
include(joinpath(@__DIR__, "framework.jl")); include(joinpath(@__DIR__, "sciml.jl"))

drive_algorithm = Dict("sine" => SineDrive(), "square pulse train" => SquareDrive(), "feedback on mean x" => FeedbackDrive(),
                   "sine + feedback together" => (SineDrive(), FeedbackDrive()))

struct Impl; name::String; setup::Function; go!::Function; result::Function; end
function impls(shape_name, force)
    [Impl("H  hand-written loop", () -> hand_setup(force), hand_loop!, s -> (s.u, s.nacc, s.nrej, length(s.snaps))),
     Impl("P  StatefulAlgorithms", () -> framework_setup(drive_algorithm[shape_name]), framework_go!, framework_result),
     Impl("S  SciML (callbacks)", () -> sciml_setup(force), sciml_go!, sciml_result)]
end

function loop_time(im::Impl, reps)
    total = 0.0
    for _ in 1:reps
        s = im.setup(); GC.gc(false)
        t0 = time_ns(); im.go!(s); total += (time_ns() - t0) / 1e9
    end
    return total / reps
end

println("Driven chain of ", PARAMS.N, " nonlinear oscillators (", 2PARAMS.N, " variables), t in [0, ", TEND,
        "], tolerance ", RTOL, ", checkpoint every ", CKPT_EVERY, " accepted steps. Loop time only.")
for (shape_name, force) in SHAPES
    ims = impls(shape_name, force)
    for im in ims; s = im.setup(); im.go!(s); end                                    # compile
    results = map(im -> (s = im.setup(); im.go!(s); im.result(s)), ims)
    best = fill(Inf, length(ims))
    for _ in 1:7, (k, im) in enumerate(ims); best[k] = min(best[k], loop_time(im, 5)); end
    println("\nforce: ", shape_name)
    uh = results[1][1]
    @printf("  %-24s %10s %22s %16s %14s %22s %20s\n", "implementation", "loop, ms", "attempts (acc + rej)", "checkpoints", "us / attempt", "loop time / H's time", "rel. diff of u(T) to H")
    for (k, im) in enumerate(ims)
        u, na, nr, ns = results[k]
        @printf("  %-24s %10.3f %14d + %-6d %16d %14.3f %22.2f %20.1e\n", im.name, best[k] * 1e3, na, nr, ns,
                best[k] / (na + nr) * 1e6, best[k] / best[1], norm(u .- uh) / norm(uh))
    end
end
