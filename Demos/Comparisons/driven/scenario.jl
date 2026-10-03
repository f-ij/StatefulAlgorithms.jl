# A driven chain of nonlinear oscillators (double-well phi^4 on-site potential, harmonic coupling, damping):
#     x_i' = v_i
#     v_i' = -a x_i - b x_i^3 + c (x_{i+1} - 2 x_i + x_{i-1}) - gamma v_i + F
# F is an external force that a separate component computes once per step and the integrator reads
# (the same pattern as a temperature protocol: written by one component, read by another).
# One run uses one force shape. All implementations do the same work: a step-size-controlled
# Dormand-Prince step, then the force for the next step, then (every few accepted steps) a checkpoint.
include(joinpath(@__DIR__, "..", "ode", "dp5.jl"))

struct ChainParams; N::Int; a::Float64; b::Float64; c::Float64; γ::Float64; end
struct ChainP; par::ChainParams; F::Float64; end            # immutable: what the package and the hand-written loop use
mutable struct ChainPm; par::ChainParams; F::Float64; end   # mutable: what SciML needs, a callback writes F into it

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

const PARAMS = ChainParams(64, -1.0, 1.0, 1.0, 1.0)     # damping 1.0: a forced periodic response, not chaos
const U0 = vcat([0.5 + 0.1 * sin(2pi * i / 64) for i in 1:64], zeros(64))
const TEND = 4000.0
const RTOL = 1e-6
const ATOL = 1e-6
const DT0 = 1e-2
const CKPT_EVERY = 20                  # a checkpoint every 20 accepted steps

#### the force shapes: functions of time and (for feedback) of the state ####
@inline mean_x(u, N) = (s = 0.0; @inbounds @simd for i in 1:N; s += u[i]; end; s / N)
@inline sine_force(t, u, N) = 0.5 * sin(0.8 * t)
@inline square_force(t, u, N) = 0.5 * (sin(0.8 * t) >= 0 ? 1.0 : -1.0)
@inline feedback_force(t, u, N) = 1.0 * (0.5 - mean_x(u, N))        # reads the state: two-way coupling
@inline sine_plus_feedback_force(t, u, N) = sine_force(t, u, N) + feedback_force(t, u, N)
const SHAPES = ["sine" => sine_force, "square pulse train" => square_force, "feedback on mean x" => feedback_force,
                "sine + feedback together" => sine_plus_feedback_force]

struct Snapshot; t::Float64; dt::Float64; u::Vector{Float64}; end
