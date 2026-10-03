# A new component that needs to READ the internal state of ANOTHER user-written component: here a kick whose size
# grows with the number of checkpoints taken so far (the checkpoint list `snaps` is the checkpointer's own state).
using Printf, LinearAlgebra, Random
include(joinpath(@__DIR__, "scenario.jl")); include(joinpath(@__DIR__, "hand.jl"))
include(joinpath(@__DIR__, "framework.jl")); include(joinpath(@__DIR__, "sciml.jl")); include(joinpath(@__DIR__, "modifiers.jl"))

#### StatefulAlgorithms: the new component, and one extra line in the block ####
@StepAlgorithm function GrowingKick(u, nacc, stale, snaps, @managed(last = 0))
    if nacc != last && nacc % KICK_EVERY == 0
        u[PARAMS.N+1] += KICK * (1 + length(snaps) / 100)      # reads the checkpointer's list
        stale = true
    end
    last = nacc
    return (; last, stale)
end

function package_growing()
    integ = ChainDP5M(); ckpt = Checkpointer()
    experiment = @CompositeAlgorithm begin
        @alias integ = integ
        @alias ckpt = ckpt
        GrowingKick(u = integ.u, nacc = integ.nacc, stale = integ.stale, snaps = ckpt.snaps)   # <- the new line
        F = SineDrive(t = integ.t)
        integ(F = F)
        ckpt(u = integ.u, t = integ.t, dt = integ.dt, nacc = integ.nacc)
    end
    la = StatefulAlgorithms.init(resolve(experiment), Init(integ; u0 = U0, par = PARAMS, rtol = RTOL))
    la = run(la; lifetime = Until(t -> t >= TEND, Var(integ, :t)))
    c = StatefulAlgorithms.getstoredcontext(la)
    return c[integ].u, c[integ].nacc, length(c[ckpt].snaps)
end

#### SciML, version A: everything in one function, the closures share the local variable `snaps` ####
function sciml_growing_A()
    N = PARAMS.N
    p = ChainPm(PARAMS, sine_force(0.0, U0, N)); snaps = Snapshot[]
    checkpoint = DiscreteCallback((u, t, i) -> i.stats.naccept % CKPT_EVERY == 0,
        i -> (push!(snaps, Snapshot(i.t, i.dtcache, copy(i.u))); nothing); save_positions = (false, false))
    growing = DiscreteCallback((u, t, i) -> i.stats.naccept % KICK_EVERY == 0,                    # <- the new callback
        i -> (i.u[N+1] += KICK * (1 + length(snaps) / 100); SciMLBase.u_modified!(i, true); nothing); save_positions = (false, false))
    drive = DiscreteCallback((u, t, i) -> true,
        function (i)
            F = sine_force(i.t, i.u, N)
            if F != i.p.F; i.p.F = F; SciMLBase.u_modified!(i, true); end
        end; save_positions = (false, false))
    integ = SciMLBase.init(ODEProblem(chain!, copy(U0), (0.0, TEND), p), DP5(); reltol = RTOL, abstol = ATOL, dt = DT0,
                           save_everystep = false, save_start = false, controller = OrdinaryDiffEqCore.IController(),
                           callback = CallbackSet(checkpoint, growing, drive))                    # <- one edited line
    SciMLBase.solve!(integ)
    return copy(integ.u), integ.stats.naccept, length(snaps)
end

#### SciML, version B: each component is a reusable function that returns a callback. The checkpoint callback hides
#### its `snaps`, so a component that needs it has to be handed it: the checkpoint constructor must be changed to return it. ####
function checkpoint_callback(every)                               # was: returned only the callback
    snaps = Snapshot[]
    cb = DiscreteCallback((u, t, i) -> i.stats.naccept % every == 0,
        i -> (push!(snaps, Snapshot(i.t, i.dtcache, copy(i.u))); nothing); save_positions = (false, false))
    return cb, snaps                                                # <- edited: also hand out the state
end
growing_kick_callback(snaps, N) = DiscreteCallback((u, t, i) -> i.stats.naccept % KICK_EVERY == 0,
    i -> (i.u[N+1] += KICK * (1 + length(snaps) / 100); SciMLBase.u_modified!(i, true); nothing); save_positions = (false, false))
function sciml_growing_B()
    N = PARAMS.N
    p = ChainPm(PARAMS, sine_force(0.0, U0, N))
    checkpoint, snaps = checkpoint_callback(CKPT_EVERY)             # <- edited call site
    drive = DiscreteCallback((u, t, i) -> true,
        function (i)
            F = sine_force(i.t, i.u, N)
            if F != i.p.F; i.p.F = F; SciMLBase.u_modified!(i, true); end
        end; save_positions = (false, false))
    integ = SciMLBase.init(ODEProblem(chain!, copy(U0), (0.0, TEND), p), DP5(); reltol = RTOL, abstol = ATOL, dt = DT0,
                           save_everystep = false, save_start = false, controller = OrdinaryDiffEqCore.IController(),
                           callback = CallbackSet(checkpoint, growing_kick_callback(snaps, N), drive))
    SciMLBase.solve!(integ)
    return copy(integ.u), integ.stats.naccept, length(snaps)
end

up, nacc_p, nsnaps_p = package_growing()
ua, nacc_a, nsnaps_a = sciml_growing_A()
ub, nacc_b, nsnaps_b = sciml_growing_B()
@printf("package:          accepted steps %d, checkpoints %d\n", nacc_p, nsnaps_p)
@printf("SciML version A:  accepted steps %d, checkpoints %d, relative difference to the package %.1e\n", nacc_a, nsnaps_a, norm(ua .- up) / norm(up))
@printf("SciML version B:  accepted steps %d, checkpoints %d, identical to version A: %s\n", nacc_b, nsnaps_b, ub == ua)
