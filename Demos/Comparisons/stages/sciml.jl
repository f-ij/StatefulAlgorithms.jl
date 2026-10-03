# The same experiment with SciML's idiom: a fixed-step solve (adaptive = false), the field in a mutable parameter written by
# a callback after each step according to a stage table, and callbacks for the loggers.
using SciMLBase, OrdinaryDiffEqCore, OrdinaryDiffEqLowOrderRK

function sciml_setup(Emax)
    N = PARAMS.N
    p = ChainPm(PARAMS, 0.0); trace = Float32[]; pairs = Tuple{Float32,Float32}[]
    polarization = DiscreteCallback((u, t, i) -> true,
        i -> (push!(trace, Float32(mean_x(i.u, N))); nothing); save_positions = (false, false))
    field_loop = DiscreteCallback((u, t, i) -> i.stats.naccept % KLOG == 0,
        i -> (push!(pairs, (Float32(i.p.F), Float32(mean_x(i.u, N)))); nothing); save_positions = (false, false))
    field = DiscreteCallback((u, t, i) -> true,
        function (i)
            E = field_after(Emax, i.stats.naccept)
            if E != i.p.F; i.p.F = E; SciMLBase.u_modified!(i, true); end
            return nothing
        end; save_positions = (false, false))
    gamma = DiscreteCallback((u, t, i) -> true,
        function (i)
            g = gamma_after(i.stats.naccept)
            if g != i.p.par.γ
                i.p.par = ChainParams(i.p.par.N, i.p.par.a, i.p.par.b, i.p.par.c, g)
                SciMLBase.u_modified!(i, true)
            end
            return nothing
        end; save_positions = (false, false))
    integ = SciMLBase.init(ODEProblem(chain!, copy(U0), (0.0, NTOTAL * DT), p), DP5(); adaptive = false, dt = DT,
                           save_everystep = false, save_start = false, callback = CallbackSet(polarization, field_loop, field, gamma))
    return (; integ, trace, pairs, Emax)
end
function sciml_go!(s)
    SciMLBase.solve!(s.integ)
    # callbacks do not run at the end of tspan: apply the last step's logging by hand
    if length(s.trace) == NTOTAL - 1
        P = Float32(mean_x(s.integ.u, PARAMS.N))
        push!(s.trace, P)
        NTOTAL % KLOG == 0 && push!(s.pairs, (Float32(s.integ.p.F), P))
    end
    return nothing
end
sciml_result(s) = (copy(s.integ.u), s.integ.t, copy(s.trace), copy(s.pairs))
