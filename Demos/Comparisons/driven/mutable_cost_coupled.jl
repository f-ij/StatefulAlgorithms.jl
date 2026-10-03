# Mutable parameters with SEVERAL coupled systems. M chains of 64 oscillators, each chain with its own parameter
# struct (a, b, c, gamma and a coupling kappa to the previous chain), in a tuple. The right-hand side is written the
# natural way, reading `sys.a` and so on inside the loop. Compared per M: immutable structs, mutable structs, and
# mutable structs with every field copied into locals by hand before the inner loop (what a function barrier or manual
# hoisting would do). Nothing writes into the parameters at run time. Hand-written Dormand-Prince loop, loop time only.
using Printf, LinearAlgebra
include(joinpath(@__DIR__, "..", "ode", "dp5.jl"))

const N = 64
const TEND = 400.0
const RTOL = 1e-6
const ATOL = 1e-6
const DT0 = 1e-2

struct SysImm; a::Float64; b::Float64; c::Float64; γ::Float64; κ::Float64; end
mutable struct SysMut; a::Float64; b::Float64; c::Float64; γ::Float64; κ::Float64; end

# one chain's contribution, parameters read inside the loop
@inline function chain_natural!(du, u, o, op, sy, F)
    @inbounds for i in 1:N
        ip = i == N ? 1 : i + 1; im = i == 1 ? N : i - 1
        x = u[o+i]; v = u[o+N+i]
        du[o+i] = v
        du[o+N+i] = -sy.a * x - sy.b * x^3 + sy.c * (u[o+ip] - 2x + u[o+im]) - sy.γ * v + sy.κ * (u[op+i] - x) + F
    end
end
# the same, every field copied into a local first
@inline function chain_hoisted!(du, u, o, op, sy, F)
    a = sy.a; b = sy.b; c = sy.c; γ = sy.γ; κ = sy.κ
    @inbounds for i in 1:N
        ip = i == N ? 1 : i + 1; im = i == 1 ? N : i - 1
        x = u[o+i]; v = u[o+N+i]
        du[o+i] = v
        du[o+N+i] = -a * x - b * x^3 + c * (u[o+ip] - 2x + u[o+im]) - γ * v + κ * (u[op+i] - x) + F
    end
end

# recursion over the tuple of systems: fully unrolled, each system has its own struct
@inline rhs_systems!(chain!, du, u, F, s, M, ::Tuple{}) = nothing
@inline function rhs_systems!(chain!, du, u, F, s, M, sys::Tuple)
    o = (s - 1) * 2N; sp = s == 1 ? M : s - 1; op = (sp - 1) * 2N
    chain!(du, u, o, op, first(sys), F)
    rhs_systems!(chain!, du, u, F, s + 1, M, Base.tail(sys))
end
rhs_natural!(du, u, p, t) = (rhs_systems!(chain_natural!, du, u, 0.5 * sin(0.8 * t), 1, length(p), p); nothing)
rhs_hoisted!(du, u, p, t) = (rhs_systems!(chain_hoisted!, du, u, 0.5 * sin(0.8 * t), 1, length(p), p); nothing)

# parameters in one plain Vector{Float64} (p = [a, b, c, gamma, kappa] per system), the common form in SciML,
# read inside the loop or copied to locals first. The Vector has the same element type as `du`.
@inline function chain_vec_natural!(du, u, o, op, p, k, F)
    @inbounds for i in 1:N
        ip = i == N ? 1 : i + 1; im = i == 1 ? N : i - 1
        x = u[o+i]; v = u[o+N+i]
        du[o+i] = v
        du[o+N+i] = -p[k+1] * x - p[k+2] * x^3 + p[k+3] * (u[o+ip] - 2x + u[o+im]) - p[k+4] * v + p[k+5] * (u[op+i] - x) + F
    end
end
@inline function chain_vec_hoisted!(du, u, o, op, p, k, F)
    a = p[k+1]; b = p[k+2]; c = p[k+3]; γ = p[k+4]; κ = p[k+5]
    @inbounds for i in 1:N
        ip = i == N ? 1 : i + 1; im = i == 1 ? N : i - 1
        x = u[o+i]; v = u[o+N+i]
        du[o+i] = v
        du[o+N+i] = -a * x - b * x^3 + c * (u[o+ip] - 2x + u[o+im]) - γ * v + κ * (u[op+i] - x) + F
    end
end
# the same static unrolling over the systems as the struct versions use, so that only the container differs
@inline rhs_vec_systems!(chain!, du, u, p, F, s, M, ::Tuple{}) = nothing
@inline function rhs_vec_systems!(chain!, du, u, p, F, s, M, rest::Tuple)
    o = (s - 1) * 2N; sp = s == 1 ? M : s - 1; op = (sp - 1) * 2N
    chain!(du, u, o, op, p, 5 * (s - 1), F)
    rhs_vec_systems!(chain!, du, u, p, F, s + 1, M, Base.tail(rest))
end
function rhs_vec(chain!, ::Val{M}) where {M}
    return function (du, u, p, t)
        rhs_vec_systems!(chain!, du, u, p, 0.5 * sin(0.8 * t), 1, M, ntuple(_ -> 0, Val(M)))
        return nothing
    end
end
setup_vec(chain!, M) = (f! = rhs_vec(chain!, Val(M)); u = make_u0(M); B = dp5_buffers(u); p = repeat([-1.0, 1.0, 1.0, 1.0, 0.1], M);
                    prob = (; f!, p); prob.f!(B.k1, u, p, 0.0); (; u, B, prob, out = Ref((0, 0))))

make_u0(M) = vcat((vcat([0.5 + 0.1 * sin(2pi * i / N + s) for i in 1:N], zeros(N)) for s in 1:M)...)
make_p(::Type{S}, M) where {S} = ntuple(s -> S(-1.0, 1.0, 1.0, 1.0, 0.1), M)

function setup(f!, S, M)
    u = make_u0(M); B = dp5_buffers(u); p = make_p(S, M); prob = (; f!, p)
    prob.f!(B.k1, u, p, 0.0)
    return (; u, B, prob, out = Ref((0, 0)))
end
function go!(s)
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
    s.out[] = (nacc, nrej); return nothing
end

function loop_time(mk, reps)
    total = 0.0
    for _ in 1:reps
        s = mk(); GC.gc(false)
        t0 = time_ns(); go!(s); total += (time_ns() - t0) / 1e9
    end
    return total / reps
end

@printf("%-4s %-46s %12s %16s %34s\n", "M", "parameter structs, how the right-hand side reads them", "loop, ms", "us / attempt", "time / immutable, reads in the loop")
for M in (1, 4, 8)
    cases = [("immutable, reads inside the loop", () -> setup(rhs_natural!, SysImm, M)),
             ("mutable, reads inside the loop", () -> setup(rhs_natural!, SysMut, M)),
             ("mutable, every field copied to a local first", () -> setup(rhs_hoisted!, SysMut, M)),
             ("one Vector{Float64} of parameters, reads in the loop", () -> setup_vec(chain_vec_natural!, M)),
             ("one Vector{Float64} of parameters, copied to locals", () -> setup_vec(chain_vec_hoisted!, M))]
    for (_, mk) in cases; s = mk(); go!(s); end
    results = [(s = mk(); go!(s); (s.u, s.out[])) for (_, mk) in cases]
    same = all(results[k][1] == results[1][1] for k in 2:length(cases))
    best = fill(Inf, length(cases))
    for _ in 1:7, (k, (_, mk)) in enumerate(cases); best[k] = min(best[k], loop_time(mk, 3)); end
    na, nr = results[1][2]
    for (k, (name, _)) in enumerate(cases)
        @printf("%-4d %-46s %12.3f %16.3f %34.3f\n", M, name, best[k] * 1e3, best[k] / (na + nr) * 1e6, best[k] / best[1])
    end
    same || println("  RESULTS DIFFER")
end
