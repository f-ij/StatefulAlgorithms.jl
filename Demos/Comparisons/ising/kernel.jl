# Shared kernel: 2D Ising Metropolis (L x L, periodic, J = 1, Int8 spins).
# Every variant calls exactly this code, so differences are the machinery around it.
using Random

const L = 32
const T0 = 3.0
const T1 = 1.0

fresh_spins() = rand(MersenneTwister(7), Int8[-1, 1], L, L)

"""One single-spin Metropolis attempt at inverse-free temperature `T` and field `h`.
Returns the change of the total magnetisation (0 if rejected)."""
@inline function flip!(spins::Matrix{Int8}, rng, T, h)
    i = rand(rng, 1:L); j = rand(rng, 1:L)
    @inbounds begin
        s = spins[i, j]
        nn = spins[mod1(i + 1, L), j] + spins[mod1(i - 1, L), j] +
             spins[i, mod1(j + 1, L)] + spins[i, mod1(j - 1, L)]
        dE = 2 * s * (nn + h)
        if dE <= 0 || rand(rng) < exp(-dE / T)
            spins[i, j] = -s
            return -2 * Int(s)
        end
    end
    return 0
end

# Protocols (functions of the step index), shared by all variants.
@inline anneal_T(step, N) = T0 + (T1 - T0) * (step - 1) / (N - 1)
@inline pulse_h(step, N) = 0.2 * sin(2pi * 4 * (step - 1) / N)

# Diagnostics, shared by all variants.
function energy(spins::Matrix{Int8}, h)
    e = 0.0
    @inbounds for j in 1:L, i in 1:L
        s = spins[i, j]
        e -= s * (spins[mod1(i + 1, L), j] + spins[i, mod1(j + 1, L)]) + h * s
    end
    return e
end
mean_mag(spins) = sum(spins) / length(spins)
top_row_mag(spins) = sum(@view spins[1, :]) / L
