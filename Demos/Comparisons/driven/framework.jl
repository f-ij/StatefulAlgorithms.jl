# The driven chain on StatefulAlgorithms. Three kinds of component, composed in one plan:
#   a drive (one StepAlgorithm per force shape)  computes F from the routed time (and state) and exposes it
#   ChainDP5                                     the adaptive Dormand-Prince step; reads F, writes nothing about forces
#   Checkpointer                                 snapshots the state every CKPT_EVERY accepted steps
# Swapping the force shape means swapping one algorithm in the plan; the integrator is not touched.
using StatefulAlgorithms

@StepAlgorithm function SineDrive(t, @managed(F = 0.0))
    F = sine_force(t, nothing, 0)
    return (; F)
end
@StepAlgorithm function SquareDrive(t, @managed(F = 0.0))
    F = square_force(t, nothing, 0)
    return (; F)
end
@StepAlgorithm function FeedbackDrive(t, u, @managed(F = 0.0))
    F = feedback_force(t, u, PARAMS.N)
    return (; F)
end

@StepAlgorithm function ChainDP5(F, @managed(u0), @managed(u = copy(u0)), @managed(B = dp5_buffers(u0)),
        @managed(t = 0.0), @managed(dt = DT0), @managed(nacc = 0), @managed(nrej = 0), @managed(Fk = NaN))
    prob = (; f! = chain!, p = ChainP(PARAMS, F))
    if F != Fk                                  # new force value: the first stage must be recomputed with it
        prob.f!(B.k1, u, prob.p, t)
        Fk = F
    end
    dtt = min(dt, TEND - t)
    err = dp5_attempt!(prob, B, u, t, dtt, RTOL, ATOL)
    fac = dp5_factor(err)
    if err <= 1
        t += dtt; dp5_accept!(u, B); nacc += 1; dt = dtt * fac
    else
        nrej += 1; dt = dtt * min(1.0, fac)
    end
    return (; t, dt, nacc, nrej, Fk)
end

@StepAlgorithm function Checkpointer(u, t, dt, nacc, @managed(snaps = Snapshot[]), @managed(last = 0))
    if nacc != last && nacc % CKPT_EVERY == 0
        push!(snaps, Snapshot(t, dt, copy(u)))
    end
    last = nacc
    return (; last)
end

# Several drives at once: they go in a nested Routine, and a small algorithm adds their forces.
@StepAlgorithm function ForceSum(F1, F2, @managed(F = 0.0))
    F = F1 + F2
    return (; F)
end

function framework_setup(drive)
    integ = ChainDP5(); ckpt = Checkpointer()
    checkpoint_routes = (Route(integ => ckpt, :u), Route(integ => ckpt, :t), Route(integ => ckpt, :dt), Route(integ => ckpt, :nacc))
    plan = if drive isa Tuple                    # (sine, feedback): a nested Routine of drives, then the sum
        sine, fb = drive; total = ForceSum()
        CompositeAlgorithm(Routine(sine, fb, (1, 1)), total, integ, ckpt, (1, 1, 1, 1),
            Route(sine => total, :F => :F1), Route(fb => total, :F => :F2), Route(total => integ, :F),
            Route(integ => sine, :t), Route(integ => fb, :t), Route(integ => fb, :u), checkpoint_routes...)
    else
        drive_routes = drive isa FeedbackDrive ? (Route(integ => drive, :t), Route(integ => drive, :u)) : (Route(integ => drive, :t),)
        CompositeAlgorithm(drive, integ, ckpt, (1, 1, 1), Route(drive => integ, :F), drive_routes..., checkpoint_routes...)
    end
    la = StatefulAlgorithms.init(resolve(plan), Init(integ; u0 = U0))
    return (; la, integ, ckpt, out = Ref{Any}(nothing))
end
framework_go!(s) = (s.out[] = run(s.la; lifetime = Until(t -> t >= TEND, Var(s.integ, :t))); nothing)
function framework_result(s)
    c = StatefulAlgorithms.getstoredcontext(s.out[])
    return (c[s.integ].u, c[s.integ].nacc, c[s.integ].nrej, length(c[s.ckpt].snaps))
end
