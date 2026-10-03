# Reproduction: `Unique(...)` in a plan adds a large fixed cost per iteration, whether or not the wrapped component runs.
# The base plan is the driven chain (sine drive, integrator, checkpointer); the variants add or wrap one component.
# Loop time only; "extra us / attempt" is the difference to the plan without the extra.
using Printf, LinearAlgebra, Random
include(joinpath(@__DIR__, "scenario.jl")); include(joinpath(@__DIR__, "hand.jl"))
include(joinpath(@__DIR__, "framework.jl")); include(joinpath(@__DIR__, "sciml.jl")); include(joinpath(@__DIR__, "modifiers.jl"))

@StepAlgorithm function NeverFires(u, @managed(count = 0)); count += 1; return (; count); end

function build(drive, extras, intervals)
    integ = ChainDP5(); ckpt = Checkpointer()
    plan = CompositeAlgorithm(drive, integ, ckpt, extras..., intervals,
        Route(drive => integ, :F), Route(integ => drive, :t),
        Route(integ => ckpt, :u), Route(integ => ckpt, :t), Route(integ => ckpt, :dt), Route(integ => ckpt, :nacc),
        [Route(integ => e, :u) for e in extras]...)
    la = StatefulAlgorithms.init(resolve(plan), Init(integ; u0 = U0))
    return (; la, integ, ckpt, out = Ref{Any}(nothing))
end
function measure(mk)
    framework_go!(mk()); framework_go!(mk())
    t = Inf; na = 0
    for _ in 1:5
        s = mk(); GC.gc(false); t0 = time_ns(); framework_go!(s); t = min(t, (time_ns() - t0) / 1e9)
        r = framework_result(s); na = r[2] + r[3]
    end
    return t / na * 1e6
end

cases = [("base plan", () -> build(SineDrive(), (), (1, 1, 1))),
         ("+ one plain component, runs every iteration", () -> build(SineDrive(), (NeverFires(),), (1, 1, 1, 1))),
         ("+ one plain component, interval 1_000_000", () -> build(SineDrive(), (NeverFires(),), (1, 1, 1, 1_000_000))),
         ("+ one Unique(component), runs every iteration", () -> build(SineDrive(), (Unique(NeverFires()),), (1, 1, 1, 1))),
         ("+ one Unique(component), interval 1_000_000", () -> build(SineDrive(), (Unique(NeverFires()),), (1, 1, 1, 1_000_000))),
         ("the drive wrapped in Unique, nothing added", () -> build(Unique(SineDrive()), (), (1, 1, 1)))]
base = measure(cases[1][2])
@printf("%-52s %14s %18s\n", "plan", "us / attempt", "extra us / attempt")
for (name, mk) in cases
    per = name == "base plan" ? base : measure(mk)
    @printf("%-52s %14.3f %18.3f\n", name, per, per - base)
end
