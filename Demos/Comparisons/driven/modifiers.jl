# Modifiers: small components that rewire INTERNAL variables of an integrator that was defined once.
#   DampingRamp         writes the damping gamma inside the integrator's parameters
#   ToleranceSchedule   writes the integrator's relative tolerance
#   StateKick           adds an impulse to the integrator's state every KICK_EVERY accepted steps
# The integrator (ChainDP5M) only exposes its internals as variables; it knows nothing about the modifiers, and no
# new struct is defined for any experiment. Which modifiers a run has is a choice made when the plan is built.
using StatefulAlgorithms, SciMLBase, OrdinaryDiffEqCore, OrdinaryDiffEqLowOrderRK

const KICK_EVERY = 500                 # accepted steps between kicks
const KICK = 0.05                      # impulse added to the velocity of oscillator 1
gamma_at(t) = PARAMS.γ * (1 - 0.2 * t / TEND)     # damping 1.0 -> 0.8 (stays out of the chaotic regime)
rtol_at(t) = RTOL * (1 + 9 * t / TEND)

#### the force is the same sine drive as before ####
#### hand-written reference, the modifiers selected at compile time ####
function hand_mod_loop!(s::HandState, ::Val{kick}, ::Val{ramp}, ::Val{tol}) where {kick,ramp,tol}
    (; u, B, snaps) = s
    N = PARAMS.N; par = PARAMS; rtol = RTOL
    t = s.t; dt = s.dt; nacc = s.nacc; nrej = s.nrej
    F = sine_force(t, u, N); Fk = F
    p = ChainP(par, F); prob = (; f! = chain!, p)
    prob.f!(B.k1, u, p, t)
    while t < TEND
        dtt = min(dt, TEND - t)
        err = dp5_attempt!(prob, B, u, t, dtt, rtol, ATOL)
        fac = dp5_factor(err)
        if err <= 1
            t += dtt; dp5_accept!(u, B); nacc += 1; dt = dtt * fac
            nacc % CKPT_EVERY == 0 && push!(snaps, Snapshot(t, dt, copy(u)))
            stale = false
            if kick && nacc % KICK_EVERY == 0
                u[N+1] += KICK; stale = true
            end
            if ramp
                γ = gamma_at(t)
                if γ != par.γ
                    par = ChainParams(par.N, par.a, par.b, par.c, γ); stale = true
                end
            end
            tol && (rtol = rtol_at(t))
            F = sine_force(t, u, N)
            if F != Fk || stale
                p = ChainP(par, F); prob = (; f! = chain!, p)
                prob.f!(B.k1, u, p, t); Fk = F
            end
        else
            nrej += 1; dt = dtt * min(1.0, fac)
        end
    end
    s.t = t; s.dt = dt; s.nacc = nacc; s.nrej = nrej
    return s
end

#### StatefulAlgorithms: the integrator defined once, then modifiers ####
@StepAlgorithm function ChainDP5M(F, @managed(u0), @managed(par), @managed(rtol), @managed(u = copy(u0)),
        @managed(B = dp5_buffers(u0)), @managed(t = 0.0), @managed(dt = DT0), @managed(nacc = 0), @managed(nrej = 0),
        @managed(Fk = NaN), @managed(stale = false))
    prob = (; f! = chain!, p = ChainP(par, F))
    if F != Fk || stale                         # the force or something inside the integrator changed
        prob.f!(B.k1, u, prob.p, t)
        Fk = F; stale = false
    end
    dtt = min(dt, TEND - t)
    err = dp5_attempt!(prob, B, u, t, dtt, rtol, ATOL)
    fac = dp5_factor(err)
    if err <= 1
        t += dtt; dp5_accept!(u, B); nacc += 1; dt = dtt * fac
    else
        nrej += 1; dt = dtt * min(1.0, fac)
    end
    return (; t, dt, nacc, nrej, Fk, stale)
end

@StepAlgorithm function DampingRamp(t, par, stale)
    γ = gamma_at(t)
    if γ != par.γ
        par = ChainParams(par.N, par.a, par.b, par.c, γ)
        stale = true
    end
    return (; par, stale)
end

@StepAlgorithm function ToleranceSchedule(t, rtol)
    rtol = rtol_at(t)
    return (; rtol)
end

@StepAlgorithm function StateKick(u, nacc, stale, @managed(last = 0))
    if nacc != last && nacc % KICK_EVERY == 0
        u[PARAMS.N+1] += KICK
        stale = true
    end
    last = nacc
    return (; last, stale)
end

function modified_setup(mods)
    integ = ChainDP5M(); ckpt = Checkpointer(); drive = SineDrive()
    parts = Any[]; routes = Any[]
    if :kick in mods
        k = StateKick(); push!(parts, k)
        push!(routes, Route(integ => k, :u), Route(integ => k, :nacc), Route(integ => k, :stale))
    end
    if :ramp in mods
        r = DampingRamp(); push!(parts, r)
        push!(routes, Route(integ => r, :t), Route(integ => r, :par), Route(integ => r, :stale))
    end
    if :tol in mods
        w = ToleranceSchedule(); push!(parts, w)
        push!(routes, Route(integ => w, :t), Route(integ => w, :rtol))
    end
    n = length(parts) + 3
    plan = CompositeAlgorithm(parts..., drive, integ, ckpt, ntuple(_ -> 1, n),
        Route(drive => integ, :F), Route(integ => drive, :t),
        Route(integ => ckpt, :u), Route(integ => ckpt, :t), Route(integ => ckpt, :dt), Route(integ => ckpt, :nacc), routes...)
    la = StatefulAlgorithms.init(resolve(plan), Init(integ; u0 = U0, par = PARAMS, rtol = RTOL))
    return (; la, integ, ckpt, out = Ref{Any}(nothing))
end

#### SciML: the same modifiers as callbacks on a mutable parameter ####
function sciml_modified_setup(mods)
    N = PARAMS.N
    p = ChainPm(PARAMS, sine_force(0.0, U0, N)); snaps = Snapshot[]
    cbs = DiscreteCallback[]
    nosave = (; save_positions = (false, false))
    push!(cbs, DiscreteCallback((u, t, i) -> i.stats.naccept % CKPT_EVERY == 0,
        i -> (push!(snaps, Snapshot(i.t, i.dtcache, copy(i.u))); nothing); nosave...))
    if :kick in mods
        push!(cbs, DiscreteCallback((u, t, i) -> i.stats.naccept % KICK_EVERY == 0,
            i -> (i.u[N+1] += KICK; SciMLBase.u_modified!(i, true); nothing); nosave...))
    end
    if :ramp in mods
        push!(cbs, DiscreteCallback((u, t, i) -> true,
            function (i)
                γ = gamma_at(i.t)
                if γ != i.p.par.γ
                    i.p.par = ChainParams(i.p.par.N, i.p.par.a, i.p.par.b, i.p.par.c, γ)
                    SciMLBase.u_modified!(i, true)
                end
                return nothing
            end; nosave...))
    end
    if :tol in mods
        push!(cbs, DiscreteCallback((u, t, i) -> true, i -> (i.opts.reltol = rtol_at(i.t); nothing); nosave...))
    end
    push!(cbs, DiscreteCallback((u, t, i) -> true,
        function (i)
            F = sine_force(i.t, i.u, N)
            if F != i.p.F
                i.p.F = F
                SciMLBase.u_modified!(i, true)
            end
            return nothing
        end; nosave...))
    integ = SciMLBase.init(ODEProblem(chain!, copy(U0), (0.0, TEND), p), DP5(); reltol = RTOL, abstol = ATOL, dt = DT0,
                           save_everystep = false, save_start = false, controller = OrdinaryDiffEqCore.IController(),
                           callback = CallbackSet(cbs...))
    return (; integ, snaps)
end
