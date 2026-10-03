# What does a mutable parameter struct cost? The same driven chain (sine force computed from t inside the
# right-hand side, so nothing writes into p), with the parameters in an immutable struct versus a mutable one,
# in SciML and in a hand-written loop, and with the right-hand side reading the parameters once at the top versus
# inside the loop. Nothing is modified at run time, so the only difference is what the struct type allows the
# compiler to do. Loop time only.
using Printf, LinearAlgebra, SciMLBase, OrdinaryDiffEqCore, OrdinaryDiffEqLowOrderRK
include(joinpath(@__DIR__, "scenario.jl"))

struct PImm; par::ChainParams; end
mutable struct PMut; par::ChainParams; end

# reads the parameters once, before the loop
function rhs_top!(du, u, p, t)
    par = p.par; N = par.N; a = par.a; b = par.b; c = par.c; γ = par.γ
    F = 0.5 * sin(0.8 * t)
    @inbounds for i in 1:N
        ip = i == N ? 1 : i + 1; im = i == 1 ? N : i - 1
        x = u[i]; v = u[N+i]
        du[i] = v
        du[N+i] = -a * x - b * x^3 + c * (u[ip] - 2x + u[im]) - γ * v + F
    end
    return nothing
end
# reads the parameters inside the loop, the way a user commonly writes it
function rhs_loop!(du, u, p, t)
    N = p.par.N
    F = 0.5 * sin(0.8 * t)
    @inbounds for i in 1:N
        ip = i == N ? 1 : i + 1; im = i == 1 ? N : i - 1
        x = u[i]; v = u[N+i]
        du[i] = v
        du[N+i] = -p.par.a * x - p.par.b * x^3 + p.par.c * (u[ip] - 2x + u[im]) - p.par.γ * v + F
    end
    return nothing
end

#### SciML: setup untimed, solve! timed ####
sciml_setup(f!, P) = SciMLBase.init(ODEProblem(f!, copy(U0), (0.0, TEND), P(PARAMS)), DP5(); reltol = RTOL, abstol = ATOL,
    dt = DT0, save_everystep = false, save_start = false, controller = OrdinaryDiffEqCore.IController())
sciml_result(i) = (copy(i.u), i.stats.naccept, i.stats.nreject)

#### hand-written loop: the same Dormand-Prince core, parameters passed in the chosen struct ####
function hand_setup(f!, P)
    u = copy(U0); B = dp5_buffers(u)
    p = P(PARAMS); prob = (; f!, p)
    prob.f!(B.k1, u, p, 0.0)
    return (; u, B, prob, r = Ref((0.0, DT0, 0, 0)))
end
function hand_go!(s)
    (; u, B, prob) = s
    t = 0.0; dt = DT0; nacc = 0; nrej = 0
    while t < TEND
        dtt = min(dt, TEND - t)
        err = dp5_attempt!(prob, B, u, t, dtt, RTOL, ATOL)
        fac = dp5_factor(err)
        if err <= 1
            t += dtt; dp5_accept!(u, B); nacc += 1; dt = dtt * fac
        else
            nrej += 1; dt = dtt * min(1.0, fac)
        end
    end
    s.r[] = (t, dt, nacc, nrej)
    return nothing
end
hand_result(s) = (copy(s.u), s.r[][3], s.r[][4])

struct Case; name::String; setup::Function; go!::Function; result::Function; end
cases = Case[]
for (rname, f!) in (("reads p once at the top", rhs_top!), ("reads p inside the loop", rhs_loop!)), (pname, P) in (("immutable p", PImm), ("mutable p", PMut))
    push!(cases, Case("SciML, $rname, $pname", () -> sciml_setup(f!, P), i -> (SciMLBase.solve!(i); nothing), sciml_result))
    push!(cases, Case("hand-written loop, $rname, $pname", () -> hand_setup(f!, P), hand_go!, hand_result))
end

function loop_time(c::Case, reps)
    total = 0.0
    for _ in 1:reps
        s = c.setup(); GC.gc(false)
        t0 = time_ns(); c.go!(s); total += (time_ns() - t0) / 1e9
    end
    return total / reps
end
for c in cases; s = c.setup(); c.go!(s); end
results = [(s = c.setup(); c.go!(s); c.result(s)) for c in cases]
best = fill(Inf, length(cases))
for _ in 1:9, (k, c) in enumerate(cases); best[k] = min(best[k], loop_time(c, 5)); end
@printf("results identical between immutable and mutable p: %s\n", all(results[k][1] == results[k+2][1] for k in (1, 2, 5, 6)))
@printf("%-52s %12s %16s %30s\n", "case", "loop, ms", "us / attempt", "time / immutable p, same case")
for (k, c) in enumerate(cases)
    na, nr = results[k][2:3]
    base = isodd(cld(k, 2)) ? best[k] : best[k-2]            # cases come in pairs (imm, mut) per implementation: k and k+2
    # layout: [SciML imm, hand imm, SciML mut, hand mut] per rhs flavour
    group = (k - 1) ÷ 4; pos = (k - 1) % 4 + 1
    immk = group * 4 + (pos in (1, 3) ? 1 : 2)
    @printf("%-52s %12.3f %16.3f %30.3f\n", c.name, best[k] * 1e3, best[k] / (na + nr) * 1e6, best[k] / best[immk])
end
