# Does exposing everything cost anything? The same integrator, once with only what it needs and once with twelve
# extra variables of mixed types (scalars, arrays, a NamedTuple) that nothing reads. Loop time only.
using Printf, LinearAlgebra
include(joinpath(@__DIR__, "scenario.jl")); include(joinpath(@__DIR__, "hand.jl"))
include(joinpath(@__DIR__, "framework.jl")); include(joinpath(@__DIR__, "sciml.jl")); include(joinpath(@__DIR__, "modifiers.jl"))

@StepAlgorithm function ChainDP5Everything(F, @managed(u0), @managed(par), @managed(rtol), @managed(u = copy(u0)),
        @managed(B = dp5_buffers(u0)), @managed(t = 0.0), @managed(dt = DT0), @managed(nacc = 0), @managed(nrej = 0),
        @managed(Fk = NaN), @managed(stale = false),
        # twelve variables that nothing reads
        @managed(x1 = 1.0), @managed(x2 = 2.0), @managed(x3 = 3), @managed(x4 = 4), @managed(x5 = zeros(64)),
        @managed(x6 = zeros(8, 8)), @managed(x7 = (; a = 1.0, b = 2.0, c = 3.0)), @managed(x8 = rand(128)),
        @managed(x9 = Float32[1, 2, 3]), @managed(x10 = Int[]), @managed(x11 = (1.0, 2, 3.0f0)), @managed(x12 = Ref(0.0)))
    prob = (; f! = chain!, p = ChainP(par, F))
    if F != Fk || stale
        prob.f!(B.k1, u, prob.p, t)
        Fk = F; stale = false
    end
    dtt = min(dt, TEND - t)
    err = dp5_attempt!(prob, B, u, t, dtt, rtol, ATOL)
    fac = dp5_factor(err)
    if err <= 1
        t += dtt; dp5_accept!(u, B); nacc += 1; dt = dtt * fac
    else
        nrej += 1; dt = dtt * min(1.0, fac)
    end
    return (; t, dt, nacc, nrej, Fk, stale)
end

function setup_with(Integ)
    integ = Integ(); ckpt = Checkpointer(); drive = SineDrive()
    plan = CompositeAlgorithm(drive, integ, ckpt, (1, 1, 1), Route(drive => integ, :F), Route(integ => drive, :t),
        Route(integ => ckpt, :u), Route(integ => ckpt, :t), Route(integ => ckpt, :dt), Route(integ => ckpt, :nacc))
    la = StatefulAlgorithms.init(resolve(plan), Init(integ; u0 = U0, par = PARAMS, rtol = RTOL))
    return (; la, integ, ckpt, out = Ref{Any}(nothing))
end

variants = [("minimal integrator (what it needs)", () -> setup_with(ChainDP5M)),
            ("same + 12 unread variables", () -> setup_with(ChainDP5Everything))]
function loop_time(setup, reps)
    total = 0.0
    for _ in 1:reps
        s = setup(); GC.gc(false)
        t0 = time_ns(); framework_go!(s); total += (time_ns() - t0) / 1e9
    end
    return total / reps
end
for (_, f) in variants; s = f(); framework_go!(s); end
results = [(s = f(); framework_go!(s); framework_result(s)) for (_, f) in variants]
best = fill(Inf, length(variants))
for _ in 1:9, (k, (_, f)) in enumerate(variants); best[k] = min(best[k], loop_time(f, 5)); end
println("results identical: ", results[1][1] == results[2][1], "   attempts ", results[1][2:3], " and ", results[2][2:3])
@printf("%-38s %12s %16s %28s\n", "integrator", "loop, ms", "us / attempt", "loop time / minimal's loop time")
for (k, (name, _)) in enumerate(variants)
    na, nr = results[k][2:3]
    @printf("%-38s %12.3f %16.3f %28.3f\n", name, best[k] * 1e3, best[k] / (na + nr) * 1e6, best[k] / best[1])
end
