# The same run with SciML's idiom: the force lives in a mutable parameter that a callback writes after each
# accepted step, and a second callback takes the checkpoints.
using SciMLBase, OrdinaryDiffEqCore, OrdinaryDiffEqLowOrderRK

function sciml_setup(force)
    N = PARAMS.N
    p = ChainPm(PARAMS, force(0.0, U0, N)); snaps = Snapshot[]
    drive_cb = DiscreteCallback((u, t, i) -> true,
        function (i)
            F = force(i.t, i.u, N)
            if F != i.p.F                            # new value: the first stage must be recomputed with it
                i.p.F = F
                SciMLBase.u_modified!(i, true)
            end
            return nothing
        end; save_positions = (false, false))
    ckpt_cb = DiscreteCallback((u, t, i) -> i.stats.naccept % CKPT_EVERY == 0,
        i -> (push!(snaps, Snapshot(i.t, i.dtcache, copy(i.u))); nothing); save_positions = (false, false))
    integ = SciMLBase.init(ODEProblem(chain!, copy(U0), (0.0, TEND), p), DP5(); reltol = RTOL, abstol = ATOL, dt = DT0,
                           save_everystep = false, save_start = false, controller = OrdinaryDiffEqCore.IController(),
                           callback = CallbackSet(drive_cb, ckpt_cb))
    return (; integ, snaps)
end
sciml_go!(s) = (SciMLBase.solve!(s.integ); nothing)
sciml_result(s) = (copy(s.integ.u), s.integ.stats.naccept, s.integ.stats.nreject, length(s.snaps))
