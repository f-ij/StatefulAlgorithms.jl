# A multi-stage "hysteresis" experiment on a chain of nonlinear oscillators (a toy ferroelectric: double-well on-site
# potential, harmonic coupling, damping), in the style of the manuscript experiments: a core (dynamics + loggers) reused by
# every stage, one protocol per stage that writes the applied field E, and the experiment a Routine of repeated stages.
#   stage 1 "preset"  : E from 0 to +Emax            (N1 steps)
#   stage 2 "down"    : E from +Emax to -Emax         (N2 steps)
#   stage 3 "up"      : E from -Emax to +Emax         (N3 steps)
#   stage 4 "return" : E from +Emax to 0                 (N4 steps)
# Fixed time step, so a stage is a number of steps. Loggers: polarization P = mean(x) every step, and the pair (E, P) every
# KLOG steps. The experiment is run for several maximum fields Emax (a sweep).
include(joinpath(@__DIR__, "..", "ode", "dp5.jl"))

struct ChainParams; N::Int; a::Float64; b::Float64; c::Float64; γ::Float64; end
struct ChainP; par::ChainParams; F::Float64; end
mutable struct ChainPm; par::ChainParams; F::Float64; end
function chain!(du, u, p, t)
    par = p.par; N = par.N; F = p.F
    @inbounds for i in 1:N
        ip = i == N ? 1 : i + 1; im = i == 1 ? N : i - 1
        x = u[i]; v = u[N+i]
        du[i] = v
        du[N+i] = -par.a * x - par.b * x^3 + par.c * (u[ip] - 2x + u[im]) - par.γ * v + F
    end
    return nothing
end

const PARAMS = ChainParams(64, -1.0, 1.0, 1.0, 1.0)
const U0 = vcat([-1.0 + 0.05 * sin(2pi * i / 64) for i in 1:64], zeros(64))     # starts in the negative well
const DT = 0.05
const EMAXES = (0.5, 0.6, 0.7, 0.8)                  # the sweep
const N1, N2, N3, N4 = 4000, 8000, 8000, 4000         # steps per stage
const KLOG = 50
stages(Emax) = ((0.0, Emax, N1), (Emax, -Emax, N2), (-Emax, Emax, N3), (Emax, 0.0, N4))
const NTOTAL = N1 + N2 + N3 + N4

@inline mean_x(u, N) = (s = 0.0; @inbounds @simd for i in 1:N; s += u[i]; end; s / N)

"""Field set after global step j (1-based) of an experiment with maximum field Emax: the ramp of the stage j falls in."""
function field_after(Emax, j)
    k = j
    for (a, b, n) in stages(Emax)
        k <= n && return a + (b - a) * (k / n)
        k -= n
    end
    return stages(Emax)[end][2]
end

# one fixed step of the Dormand-Prince 5 stages without the error estimate (SciML with adaptive = false does not compute one)
@inline function dp5_step!(prob, B, u, t, dt)
    f! = prob.f!; p = prob.p
    (; k1, k2, k3, k4, k5, k6, k7, ytmp, unew) = B
    n = length(u)
    @inbounds @simd for i in 1:n; ytmp[i] = u[i] + dt * (A21 * k1[i]); end
    f!(k2, ytmp, p, t + C2 * dt)
    @inbounds @simd for i in 1:n; ytmp[i] = u[i] + dt * (A31 * k1[i] + A32 * k2[i]); end
    f!(k3, ytmp, p, t + C3 * dt)
    @inbounds @simd for i in 1:n; ytmp[i] = u[i] + dt * (A41 * k1[i] + A42 * k2[i] + A43 * k3[i]); end
    f!(k4, ytmp, p, t + C4 * dt)
    @inbounds @simd for i in 1:n; ytmp[i] = u[i] + dt * (A51 * k1[i] + A52 * k2[i] + A53 * k3[i] + A54 * k4[i]); end
    f!(k5, ytmp, p, t + C5 * dt)
    @inbounds @simd for i in 1:n; ytmp[i] = u[i] + dt * (A61 * k1[i] + A62 * k2[i] + A63 * k3[i] + A64 * k4[i] + A65 * k5[i]); end
    f!(k6, ytmp, p, t + dt)
    @inbounds @simd for i in 1:n; unew[i] = u[i] + dt * (A71 * k1[i] + A73 * k3[i] + A74 * k4[i] + A75 * k5[i] + A76 * k6[i]); end
    f!(k7, unew, p, t + dt)
    return nothing
end

# the change made after the experiment was written: in stage 2 only, the damping also ramps from its value to GAMMA_END (and stays there)
const GAMMA_END = 0.6
gamma_after(j) = j <= N1 ? PARAMS.γ : j <= N1 + N2 ? PARAMS.γ + (GAMMA_END - PARAMS.γ) * ((j - N1) / N2) : GAMMA_END
