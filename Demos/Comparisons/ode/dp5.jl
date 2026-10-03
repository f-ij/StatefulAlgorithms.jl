# Dormand-Prince 5(4), adaptive, written once as a plain core and used by both the
# hand-written loop and the StatefulAlgorithms steps, so they do exactly the same arithmetic.
const C2, C3, C4, C5 = 1 / 5, 3 / 10, 4 / 5, 8 / 9
const A21 = 1 / 5
const A31, A32 = 3 / 40, 9 / 40
const A41, A42, A43 = 44 / 45, -56 / 15, 32 / 9
const A51, A52, A53, A54 = 19372 / 6561, -25360 / 2187, 64448 / 6561, -212 / 729
const A61, A62, A63, A64, A65 = 9017 / 3168, -355 / 33, 46732 / 5247, 49 / 176, -5103 / 18656
const A71, A73, A74, A75, A76 = 35 / 384, 500 / 1113, 125 / 192, -2187 / 6784, 11 / 84
const E1, E3, E4, E5, E6, E7 = 71 / 57600, -71 / 16695, 71 / 1920, -17253 / 339200, 22 / 525, -1 / 40
const QMIN, QMAX, SAFETY = 0.2, 10.0, 0.9

dp5_buffers(u0) = (; k1 = similar(u0), k2 = similar(u0), k3 = similar(u0), k4 = similar(u0), k5 = similar(u0),
                     k6 = similar(u0), k7 = similar(u0), ytmp = similar(u0), unew = similar(u0))
# Same buffers, but the NamedTuple shape is only known at run time: the compiler cannot infer it.
# This is the pattern the init step exists for: build such things before a function barrier.
dp5_buffers_dynamic(u0) = (; (Symbol(:k, i) => similar(u0) for i in 1:7)..., ytmp = similar(u0), unew = similar(u0))

"""One attempt with step `dt` from `(t, u)`; needs `B.k1 = f(t, u)`. Returns the scaled error norm
(<= 1 means accept). Leaves the 5th-order candidate in `B.unew` and `f(t+dt, unew)` in `B.k7`."""
@inline function dp5_attempt!(prob, B, u, t, dt, rtol, atol)
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
    acc = 0.0
    @inbounds for i in 1:n
        e = dt * (E1 * k1[i] + E3 * k3[i] + E4 * k4[i] + E5 * k5[i] + E6 * k6[i] + E7 * k7[i])
        sc = atol + rtol * max(abs(u[i]), abs(unew[i]))
        acc += (e / sc)^2
    end
    return sqrt(acc / n)
end

"""I-controller: the next step size factor from the error norm."""
@inline dp5_factor(err) = err == 0 ? QMAX : min(QMAX, max(QMIN, SAFETY * err^(-1 / 5)))

@inline function dp5_accept!(u, B)
    copyto!(u, B.unew); copyto!(B.k1, B.k7)   # FSAL: the last stage is the next first stage
    return nothing
end

#### H. hand-written adaptive loop ####
dp5_hand(prob, rtol, atol) = dp5_hand(prob, rtol, atol, dp5_buffers(prob.u0))
"""Hand-written loop with buffers built by the caller (the function barrier is the call itself)."""
function dp5_hand(prob, rtol, atol, B)
    u = copy(prob.u0); t = 0.0; dt = prob.dt0; nacc = 0; nrej = 0
    prob.f!(B.k1, u, prob.p, t)
    while t < prob.tend
        dtt = min(dt, prob.tend - t)
        err = dp5_attempt!(prob, B, u, t, dtt, rtol, atol)
        fac = dp5_factor(err)
        if err <= 1
            t += dtt; dp5_accept!(u, B); nacc += 1; dt = dtt * fac
        else
            nrej += 1; dt = dtt * min(1.0, fac)
        end
    end
    return (u, nacc, nrej)
end

#### H0. hand-written, buffers of unknown type used in the same function (no barrier) ####
function dp5_hand_nobarrier(prob, rtol, atol)
    u = copy(prob.u0); B = dp5_buffers_dynamic(u); t = 0.0; dt = prob.dt0; nacc = 0; nrej = 0
    prob.f!(B.k1, u, prob.p, t)
    while t < prob.tend
        dtt = min(dt, prob.tend - t)
        err = dp5_attempt!(prob, B, u, t, dtt, rtol, atol)
        fac = dp5_factor(err)
        if err <= 1
            t += dtt; dp5_accept!(u, B); nacc += 1; dt = dtt * fac
        else
            nrej += 1; dt = dtt * min(1.0, fac)
        end
    end
    return (u, nacc, nrej)
end
