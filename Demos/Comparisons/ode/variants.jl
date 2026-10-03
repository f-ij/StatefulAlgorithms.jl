using StatefulAlgorithms, SciMLBase, OrdinaryDiffEqCore, OrdinaryDiffEqLowOrderRK, OrdinaryDiffEqTsit5,
      OrdinaryDiffEqRosenbrock, OrdinaryDiffEqVerner
using LinearAlgebra

odeprob(prob::Problem) = ODEProblem(prob.f!, copy(prob.u0), (0.0, prob.tend), prob.p)

#### S. SciML directly ####
function sciml_solve(prob, alg, rtol, atol)
    sol = solve(odeprob(prob), alg; reltol = rtol, abstol = atol, dt = prob.dt0, save_everystep = false,
                save_start = false, controller = OrdinaryDiffEqCore.IController())
    return (sol.u[end], sol.stats.naccept, sol.stats.nreject)
end

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

function dp5_framework(prob, rtol, atol)
    algo = DP5Attempt()
    ip = InlineProcess(algo, Init(algo; prob, rtol, atol); lifetime = Until(t -> t >= prob.tend, Var(algo, :t)))
    run(ip)
    c = context(ip)[algo]
    return (c.u, c.nacc, c.nrej)
end

#### W. SciML's integrator hosted inside a StatefulAlgorithms step (wrap, don't rewrite) ####
@StepAlgorithm function SciMLHost(@managed(prob), @managed(alg), @managed(rtol), @managed(atol),
        @managed(integ = SciMLBase.init(odeprob(prob), alg; reltol = rtol, abstol = atol, dt = prob.dt0,
                                        save_everystep = false, save_start = false, controller = OrdinaryDiffEqCore.IController())),
        @managed(t = 0.0))
    SciMLBase.step!(integ)
    t = integ.t
    return (; t)
end

function sciml_hosted(prob, alg, rtol, atol)
    algo = SciMLHost()
    ip = InlineProcess(algo, Init(algo; prob, alg, rtol, atol); lifetime = Until(t -> t >= prob.tend, Var(algo, :t)))
    run(ip)
    integ = context(ip)[algo].integ
    return (copy(integ.u), integ.stats.naccept, integ.stats.nreject)
end

reference(prob) = solve(odeprob(prob), Vern9(); reltol = 1e-14, abstol = 1e-14, save_everystep = false).u[end]
