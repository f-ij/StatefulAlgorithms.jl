# The code a USER writes for the full experiment (sine drive + checkpoints + three modifiers on internal
# variables), with the library parts hidden: for StatefulAlgorithms the integrator `ChainDP5M` and the stock
# `Checkpointer` (framework.jl, modifiers.jl); for SciML the solver. The right-hand side `chain!` and the force
# functions are the same shared system definition on both sides and are not counted.
#
# Components the user defines for StatefulAlgorithms: SineDrive, DampingRamp, ToleranceSchedule, StateKick
# (in framework.jl and modifiers.jl, 4 + 7 + 4 + 8 lines). They could also come from a library of drives.

#### StatefulAlgorithms: the composition ####
function package_experiment()
    integ = ChainDP5M()
    experiment = @CompositeAlgorithm begin
        @alias integ = integ
        StateKick(u = integ.u, nacc = integ.nacc, stale = integ.stale)
        DampingRamp(t = integ.t, par = integ.par, stale = integ.stale)
        ToleranceSchedule(t = integ.t, rtol = integ.rtol)
        F = SineDrive(t = integ.t)
        integ(F = F)
        Checkpointer(u = integ.u, t = integ.t, dt = integ.dt, nacc = integ.nacc)
    end
    la = StatefulAlgorithms.init(resolve(experiment), Init(integ; u0 = U0, par = PARAMS, rtol = RTOL))
    return run(la; lifetime = Until(t -> t >= TEND, Var(integ, :t))), integ
end

#### SciML: everything the user writes (callbacks on a mutable parameter, then the solve) ####
function sciml_experiment()
    N = PARAMS.N
    p = ChainPm(PARAMS, sine_force(0.0, U0, N)); snaps = Snapshot[]
    checkpoint = DiscreteCallback((u, t, i) -> i.stats.naccept % CKPT_EVERY == 0,
        i -> (push!(snaps, Snapshot(i.t, i.dtcache, copy(i.u))); nothing); save_positions = (false, false))
    kick = DiscreteCallback((u, t, i) -> i.stats.naccept % KICK_EVERY == 0,
        i -> (i.u[N+1] += KICK; SciMLBase.u_modified!(i, true); nothing); save_positions = (false, false))
    ramp = DiscreteCallback((u, t, i) -> true,
        function (i)
            γ = gamma_at(i.t)
            if γ != i.p.par.γ
                i.p.par = ChainParams(i.p.par.N, i.p.par.a, i.p.par.b, i.p.par.c, γ)
                SciMLBase.u_modified!(i, true)
            end
        end; save_positions = (false, false))
    tolerance = DiscreteCallback((u, t, i) -> true, i -> (i.opts.reltol = rtol_at(i.t); nothing); save_positions = (false, false))
    drive = DiscreteCallback((u, t, i) -> true,
        function (i)
            F = sine_force(i.t, i.u, N)
            if F != i.p.F
                i.p.F = F
                SciMLBase.u_modified!(i, true)
            end
        end; save_positions = (false, false))
    integ = SciMLBase.init(ODEProblem(chain!, copy(U0), (0.0, TEND), p), DP5(); reltol = RTOL, abstol = ATOL, dt = DT0,
                           save_everystep = false, save_start = false, controller = OrdinaryDiffEqCore.IController(),
                           callback = CallbackSet(checkpoint, kick, ramp, tolerance, drive))
    SciMLBase.solve!(integ)
    return integ, snaps
end
