# Test problems as plain data: right-hand side f!(du, u, p, t), parameters, initial state, horizon.
using LinearAlgebra

struct Problem{F,P,U}
    name::String
    f!::F
    p::P
    u0::U
    tend::Float64
    dt0::Float64            # initial step handed to every solver
end

#### Lorenz: 3 variables, so per-step overhead dominates ####
function lorenz!(du, u, p, t)
    σ, ρ, β = p
    @inbounds begin
        du[1] = σ * (u[2] - u[1])
        du[2] = u[1] * (ρ - u[3]) - u[2]
        du[3] = u[1] * u[2] - β * u[3]
    end
    return nothing
end
lorenz() = Problem("Lorenz (3 vars, non-stiff)", lorenz!, (10.0, 28.0, 8 / 3), [1.0, 0.0, 0.0], 5.0, 1e-3)

#### Brusselator on an N x N periodic grid, method of lines: 2N^2 variables ####
struct BrussP; N::Int; ν::Float64; A::Float64; B::Float64; end
function brusselator!(du, u, p::BrussP, t)
    N = p.N; A = p.A; B = p.B; c = p.ν * (N - 1)^2
    U = reshape(@view(u[1:N^2]), N, N); V = reshape(@view(u[N^2+1:end]), N, N)
    dU = reshape(@view(du[1:N^2]), N, N); dV = reshape(@view(du[N^2+1:end]), N, N)
    @inbounds for j in 1:N, i in 1:N
        ip = i == N ? 1 : i + 1; im = i == 1 ? N : i - 1
        jp = j == N ? 1 : j + 1; jm = j == 1 ? N : j - 1
        lu = U[ip, j] + U[im, j] + U[i, jp] + U[i, jm] - 4U[i, j]
        lv = V[ip, j] + V[im, j] + V[i, jp] + V[i, jm] - 4V[i, j]
        uv = U[i, j]^2 * V[i, j]
        dU[i, j] = A + uv - (B + 1) * U[i, j] + c * lu
        dV[i, j] = B * U[i, j] - uv + c * lv
    end
    return nothing
end
function brusselator(N = 32)
    xs = range(0, 1; length = N)
    u0 = vcat(vec([22 * (y * (1 - y))^1.5 for x in xs, y in xs]), vec([27 * (x * (1 - x))^1.5 for x in xs, y in xs]))
    Problem("Brusselator PDE ($(N)x$(N) grid, $(2N^2) vars)", brusselator!, BrussP(N, 2e-3, 1.0, 3.4), u0, 1.0, 1e-3)
end

#### Robertson: the classic stiff chemical kinetics problem ####
function robertson!(du, u, p, t)
    @inbounds begin
        du[1] = -0.04u[1] + 1e4 * u[2] * u[3]
        du[2] = 0.04u[1] - 1e4 * u[2] * u[3] - 3e7 * u[2]^2
        du[3] = 3e7 * u[2]^2
    end
    return nothing
end
robertson(tend = 100.0) = Problem("Robertson (stiff)", robertson!, nothing, [1.0, 0.0, 0.0], tend, 1e-6)
