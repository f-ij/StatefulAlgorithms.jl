# Does an item that never fires cost anything? The base experiment (sine drive + checkpoints) plus K extra items that
# never do anything: in SciML, K DiscreteCallbacks whose condition is false (the condition is still evaluated after every
# accepted step); in StatefulAlgorithms, K components of distinct types scheduled at an interval of one million iterations (they never run
# within this run). Loop time only.
using Printf, LinearAlgebra, Random
include(joinpath(@__DIR__, "scenario.jl")); include(joinpath(@__DIR__, "hand.jl"))
include(joinpath(@__DIR__, "framework.jl")); include(joinpath(@__DIR__, "sciml.jl")); include(joinpath(@__DIR__, "modifiers.jl"))

# K distinct component types (identical instances of one type share one entry in the plan)
for k in 1:8
    @eval @StepAlgorithm function $(Symbol(:NeverFires, k))(u, @managed(count = 0))
        count += 1
        return (; count)
    end
end

function package_setup(K)
    integ = ChainDP5(); ckpt = Checkpointer(); drive = SineDrive()
    extras = [getfield(Main, Symbol(:NeverFires, k))() for k in 1:K]
    intervals = (1, 1, 1, ntuple(_ -> 1_000_000, K)...)
    plan = CompositeAlgorithm(drive, integ, ckpt, extras..., intervals,
        Route(drive => integ, :F), Route(integ => drive, :t),
        Route(integ => ckpt, :u), Route(integ => ckpt, :t), Route(integ => ckpt, :dt), Route(integ => ckpt, :nacc),
        [Route(integ => e, :u) for e in extras]...)
    la = StatefulAlgorithms.init(resolve(plan), Init(integ; u0 = U0))
    return (; la, integ, ckpt, out = Ref{Any}(nothing))
end

function sciml_setup_k(K)
    N = PARAMS.N
    p = ChainPm(PARAMS, sine_force(0.0, U0, N)); snaps = Snapshot[]
    cbs = DiscreteCallback[]
    push!(cbs, DiscreteCallback((u, t, i) -> i.stats.naccept % CKPT_EVERY == 0,
        i -> (push!(snaps, Snapshot(i.t, i.dtcache, copy(i.u))); nothing); save_positions = (false, false)))
    for _ in 1:K
        push!(cbs, DiscreteCallback((u, t, i) -> i.stats.naccept == -1, i -> nothing; save_positions = (false, false)))   # never true
    end
    push!(cbs, DiscreteCallback((u, t, i) -> true,
        function (i)
            F = sine_force(i.t, i.u, N)
            if F != i.p.F; i.p.F = F; SciMLBase.u_modified!(i, true); end
        end; save_positions = (false, false)))
    integ = SciMLBase.init(ODEProblem(chain!, copy(U0), (0.0, TEND), p), DP5(); reltol = RTOL, abstol = ATOL, dt = DT0,
                           save_everystep = false, save_start = false, controller = OrdinaryDiffEqCore.IController(),
                           callback = CallbackSet(cbs...))
    return (; integ, snaps)
end

struct Impl; name::String; setup::Function; go!::Function; result::Function; end
impls(K) = [Impl("P  StatefulAlgorithms", () -> package_setup(K), framework_go!, framework_result),
            Impl("S  SciML (callbacks)", () -> sciml_setup_k(K), sciml_go!, sciml_result)]
function loop_time(im::Impl, reps)
    total = 0.0
    for _ in 1:reps
        s = im.setup(); GC.gc(false)
        t0 = time_ns(); im.go!(s); total += (time_ns() - t0) / 1e9
    end
    return total / reps
end

@printf("%-26s %-8s %12s %16s %20s\n", "implementation", "extra", "loop, ms", "us / attempt", "us / attempt vs 0 extra")
base = Dict{String,Float64}()
for K in (0, 2, 4, 8)
    ims = impls(K)
    for im in ims; s = im.setup(); im.go!(s); end
    results = map(im -> (s = im.setup(); im.go!(s); im.result(s)), ims)
    best = fill(Inf, length(ims))
    for _ in 1:7, (k, im) in enumerate(ims); best[k] = min(best[k], loop_time(im, 5)); end
    for (k, im) in enumerate(ims)
        na, nr = results[k][2:3]; per = best[k] / (na + nr) * 1e6
        K == 0 && (base[im.name] = per)
        @printf("%-26s %-8d %12.3f %16.3f %20.3f\n", im.name, K, best[k] * 1e3, per, per - base[im.name])
    end
end
