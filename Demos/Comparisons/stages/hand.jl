# Hand-written monolith: one loop over the stages, everything a local.
mutable struct HandState{Bt}
    u::Vector{Float64}; B::Bt; trace::Vector{Float32}; pairs::Vector{Tuple{Float32,Float32}}; Emax::Float64; t::Float64
end
hand_setup(Emax) = HandState(copy(U0), dp5_buffers(U0), Float32[], Tuple{Float32,Float32}[], Emax, 0.0)

function hand_go!(s::HandState)
    (; u, B, trace, pairs) = s
    N = PARAMS.N
    E = 0.0; Ek = NaN; t = 0.0; j = 0; par = PARAMS; stale = false
    for (si, (a, b, n)) in enumerate(stages(s.Emax))
        for k in 1:n
            prob = (; f! = chain!, p = ChainP(par, E))
            if E != Ek || stale
                prob.f!(B.k1, u, prob.p, t); Ek = E; stale = false
            end
            dp5_step!(prob, B, u, t, DT)
            t += DT; dp5_accept!(u, B)
            P = Float32(mean_x(u, N))
            push!(trace, P)
            j += 1
            j % KLOG == 0 && push!(pairs, (Float32(E), P))
            E = a + (b - a) * (k / n)                   # the ramp, after the step
            if si == 2
                par = ChainParams(par.N, par.a, par.b, par.c, PARAMS.γ + (GAMMA_END - PARAMS.γ) * (k / n)); stale = true
            end
        end
    end
    s.t = t
    return nothing
end
hand_result(s) = (copy(s.u), s.t, copy(s.trace), copy(s.pairs))
