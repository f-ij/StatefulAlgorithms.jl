using StatefulAlgorithms, SciMLBase, OrdinaryDiffEqCore, OrdinaryDiffEqLowOrderRK, OrdinaryDiffEqTsit5,
      OrdinaryDiffEqRosenbrock, OrdinaryDiffEqVerner
using LinearAlgebra

odeprob(prob::Problem) = ODEProblem(prob.f!, copy(prob.u0), (0.0, prob.tend), prob.p)

"""
A variant is timed in two parts. `setup(prob, rtol, atol)` builds everything (integrator, process, buffers)
and is NOT timed; `go!(state)` runs only the loop and is the timed part; `result(state)` returns
`(u, accepted, rejected)` for the correctness check.
"""
struct Variant
    name::String
    setup::Function
    go!::Function
    result::Function
end

sciml_integrator(prob, alg, rtol, atol) =
    SciMLBase.init(odeprob(prob), alg; reltol = rtol, abstol = atol, dt = prob.dt0, save_everystep = false,
                   save_start = false, controller = OrdinaryDiffEqCore.IController())
integ_result(integ) = (copy(integ.u), integ.stats.naccept, integ.stats.nreject)

#### SciML: solve!() on a built integrator, and a plain step! loop on a built integrator ####
sciml_solve_variant(name, alg) = Variant(name, (p, r, a) -> sciml_integrator(p, alg, r, a),
    integ -> SciMLBase.solve!(integ), integ_result)

# init's return type is not inferable, so the loop runs in a function that receives the integrator
@noinline function drive!(integ, tend)
    while integ.t < tend
        SciMLBase.step!(integ)
    end
    return integ
end
sciml_loop_variant(name, alg) = Variant(name, (p, r, a) -> (; integ = sciml_integrator(p, alg, r, a), tend = p.tend),
    s -> drive!(s.integ, s.tend), s -> integ_result(s.integ))

#### H / H0: hand-written loops (dp5.jl) ####
hand_variant(name) = Variant(name, dp5_state, dp5_loop!, s -> (s.u, s.nacc, s.nrej))
hand_untyped_variant(name) = Variant(name, dp5_state_untyped, dp5_loop_untyped!, s -> (s.u, s.nacc, s.nrej))

#### R. the same Dormand-Prince written as a StatefulAlgorithms step: one attempt per call ####
@StepAlgorithm function DP5Attempt(@managed(prob), @managed(rtol), @managed(atol),
        @managed(u = copy(prob.u0)), @managed(B = dp5_buffers(prob.u0)), @managed(t = 0.0),
        @managed(dt = prob.dt0), @managed(nacc = 0), @managed(nrej = 0), @managed(started = false))
    if !started
        prob.f!(B.k1, u, prob.p, t)
        started = true
    end
    dtt = min(dt, prob.tend - t)
    err = dp5_attempt!(prob, B, u, t, dtt, rtol, atol)
    fac = dp5_factor(err)
    if err <= 1
        t += dtt; dp5_accept!(u, B); nacc += 1; dt = dtt * fac
    else
        nrej += 1; dt = dtt * min(1.0, fac)
    end
    return (; t, dt, nacc, nrej, started)
end

@StepAlgorithm @inline function DP5AttemptInline(@managed(prob), @managed(rtol), @managed(atol),
        @managed(u = copy(prob.u0)), @managed(B = dp5_buffers(prob.u0)), @managed(t = 0.0),
        @managed(dt = prob.dt0), @managed(nacc = 0), @managed(nrej = 0), @managed(started = false))
    if !started
        prob.f!(B.k1, u, prob.p, t)
        started = true
    end
    dtt = min(dt, prob.tend - t)
    err = dp5_attempt!(prob, B, u, t, dtt, rtol, atol)
    fac = dp5_factor(err)
    if err <= 1
        t += dtt; dp5_accept!(u, B); nacc += 1; dt = dtt * fac
    else
        nrej += 1; dt = dtt * min(1.0, fac)
    end
    return (; t, dt, nacc, nrej, started)
end


framework_variant(name, T = DP5Attempt) = Variant(name,
    function (prob, rtol, atol)
        algo = T()
        return (; algo, ip = InlineProcess(algo, Init(algo; prob, rtol, atol); lifetime = Until(t -> t >= prob.tend, Var(algo, :t))))
    end,
    s -> run(s.ip),
    s -> (c = context(s.ip)[s.algo]; (c.u, c.nacc, c.nrej)))

#### W. SciML's integrator hosted inside a StatefulAlgorithms step (wrap, don't rewrite) ####
@StepAlgorithm function SciMLHost(@managed(integ), @managed(t = 0.0))
    SciMLBase.step!(integ)
    t = integ.t
    return (; t)
end

hosted_variant(name, alg) = Variant(name,
    function (prob, rtol, atol)
        algo = SciMLHost()
        integ = sciml_integrator(prob, alg, rtol, atol)
        return (; algo, integ, ip = InlineProcess(algo, Init(algo; integ); lifetime = Until(t -> t >= prob.tend, Var(algo, :t))))
    end,
    s -> run(s.ip), s -> integ_result(s.integ))

reference(prob) = solve(odeprob(prob), Vern9(); reltol = 1e-14, abstol = 1e-14, save_everystep = false).u[end]
