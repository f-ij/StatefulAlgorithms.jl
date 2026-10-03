# `Unique(...)` in a plan: is there a cost per iteration, or only a cost the first time a new plan runs?
# Unique() creates a new random id that becomes a TYPE parameter, so every call makes a new type, and a plan built with a fresh
# Unique is a new type and is compiled the first time it runs. Two measurements on the driven-chain plan:
#   (1) loop time per attempt with the Unique created ONCE and reused (compile excluded), against plain components;
#   (2) time of the first run of a plan built with a FRESH Unique each time (includes compiling it), against plain components.
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
function loop_per_attempt(mk)
    framework_go!(mk()); framework_go!(mk())                           # compile this plan's type
    t = Inf; na = 0
    for _ in 1:5
        s = mk(); GC.gc(false); t0 = time_ns(); framework_go!(s); t = min(t, (time_ns() - t0) / 1e9)
        r = framework_result(s); na = r[2] + r[3]
    end
    return t / na * 1e6
end
function first_run_ms(mk)
    s = mk(); t0 = time_ns(); framework_go!(s); return (time_ns() - t0) / 1e6
end

# the same Unique instances, reused across all repetitions
U_extra = Unique(NeverFires()); U_drive = Unique(SineDrive())
cases = [("base plan", () -> build(SineDrive(), (), (1, 1, 1))),
         ("+ one plain component, interval 1_000_000", () -> build(SineDrive(), (NeverFires(),), (1, 1, 1, 1_000_000))),
         ("+ one Unique component (reused instance), runs every iteration", () -> build(SineDrive(), (U_extra,), (1, 1, 1, 1))),
         ("+ one Unique component (reused instance), interval 1_000_000", () -> build(SineDrive(), (U_extra,), (1, 1, 1, 1_000_000))),
         ("the drive wrapped in Unique (reused instance), nothing added", () -> build(U_drive, (), (1, 1, 1)))]
base = loop_per_attempt(cases[1][2])
println("(1) loop time, compile excluded, the Unique created once and reused")
@printf("%-66s %14s %18s\n", "plan", "us / attempt", "extra us / attempt")
for (name, mk) in cases
    per = name == "base plan" ? base : loop_per_attempt(mk)
    @printf("%-66s %14.3f %18.3f\n", name, per, per - base)
end

println("\n(2) first run of a plan built with a FRESH Unique each time (includes compiling the plan's loop), in milliseconds")
fresh_unique() = build(SineDrive(), (Unique(NeverFires()),), (1, 1, 1, 1_000_000))
fresh_plain_distinct() = (k = rand(1:10^9); build(SineDrive(), (), (1, 1, 1)))   # same type every time: compiled already
first_run_ms(fresh_unique); first_run_ms(fresh_unique)
@printf("%-66s %12s\n", "plan", "first run, ms")
@printf("%-66s %12.1f\n", "plan with a fresh Unique (first run of this plan)", first_run_ms(fresh_unique))
@printf("%-66s %12.1f\n", "plan with a fresh Unique (another fresh one)", first_run_ms(fresh_unique))
@printf("%-66s %12.1f\n", "plan without Unique, same type as before (already compiled)", first_run_ms(fresh_plain_distinct))
@printf("%-66s %12.1f\n", "the same Unique instance reused (already compiled)", first_run_ms(() -> build(SineDrive(), (U_extra,), (1, 1, 1, 1_000_000))))
