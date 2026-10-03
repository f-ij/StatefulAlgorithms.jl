# Hand-written reference: one loop, the force a local variable.
mutable struct HandState{Bt,F}
    u::Vector{Float64}; B::Bt; t::Float64; dt::Float64; nacc::Int; nrej::Int; snaps::Vector{Snapshot}; force::F
end
hand_setup(force) = HandState(copy(U0), dp5_buffers(U0), 0.0, DT0, 0, 0, Snapshot[], force)

function hand_loop!(s::HandState)
    (; u, B, force, snaps) = s
    N = PARAMS.N
    t = s.t; dt = s.dt; nacc = s.nacc; nrej = s.nrej
    F = force(t, u, N); Fk = F
    p = ChainP(PARAMS, F); prob = (; f! = chain!, p)
    prob.f!(B.k1, u, p, t)
    while t < TEND
        dtt = min(dt, TEND - t)
        err = dp5_attempt!(prob, B, u, t, dtt, RTOL, ATOL)
        fac = dp5_factor(err)
        if err <= 1
            t += dtt; dp5_accept!(u, B); nacc += 1; dt = dtt * fac
            nacc % CKPT_EVERY == 0 && push!(snaps, Snapshot(t, dt, copy(u)))
            F = force(t, u, N)                     # the force for the next step, from the new state
            if F != Fk                              # new value: the first stage must be recomputed with it
                p = ChainP(PARAMS, F); prob = (; f! = chain!, p)
                prob.f!(B.k1, u, p, t); Fk = F
            end
        else
            nrej += 1; dt = dtt * min(1.0, fac)
        end
    end
    s.t = t; s.dt = dt; s.nacc = nacc; s.nrej = nrej
    return s
end
