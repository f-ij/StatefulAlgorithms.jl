# The experiment on StatefulAlgorithms, in the manuscript style.
using StatefulAlgorithms

# the dynamics: a fixed-step integrator that owns the applied field E; protocols write E by name
@StepAlgorithm function ChainFixed(@managed(u0), @managed(par), @managed(u = copy(u0)), @managed(B = dp5_buffers(u0)),
        @managed(t = 0.0), @managed(E = 0.0), @managed(Ek = NaN), @managed(stale = false))
    prob = (; f! = chain!, p = ChainP(par, E))
    if E != Ek || stale                             # the field or something inside the integrator changed
        prob.f!(B.k1, u, prob.p, t)
        Ek = E; stale = false
    end
    dp5_step!(prob, B, u, t, DT)
    t += DT; dp5_accept!(u, B)
    return (; t, Ek, stale)
end

@StepAlgorithm function Polarization(u, @managed(trace = Float32[]))
    push!(trace, Float32(mean_x(u, PARAMS.N)))
    return (;)
end

@StepAlgorithm function FieldLoop(u, E, @managed(pairs = Tuple{Float32,Float32}[]))
    push!(pairs, (Float32(E), Float32(mean_x(u, PARAMS.N))))
    return (;)
end

# a protocol: a linear ramp of the field over n steps, written into the dynamics' variable E
@StepAlgorithm begin
    @config start::Float64 = 0.0
    @config stop::Float64 = 1.0
    @config n::Int = 1
    function FieldRamp(E, @managed(k = 0))
        k += 1
        E = start + (stop - start) * (k / n)
        return (; E, k)
    end
end

# a second protocol: a linear ramp of the damping inside the dynamics' parameters
@StepAlgorithm begin
    @config start::Float64 = 1.0
    @config stop::Float64 = 0.6
    @config n::Int = 1
    function GammaRamp(par, @managed(k = 0))
        k += 1
        par = ChainParams(par.N, par.a, par.b, par.c, start + (stop - start) * (k / n))
        return (; par, k)
    end
end

# The experiment: the core (dynamics + loggers) is built once and reused by every stage through @context; each stage adds its
# own protocol; the experiment is a Routine of repeated stages.
function framework_experiment(Emax)
    integ = ChainFixed()
    core = @CompositeAlgorithm begin
        @alias integ = integ
        integ()
        Polarization(u = integ.u)
        @every KLOG FieldLoop(u = integ.u, E = integ.E)
    end
    (a1, b1, n1), (a2, b2, n2), (a3, b3, n3), (a4, b4, n4) = stages(Emax)
    ramp1 = FieldRamp(start = a1, stop = b1, n = n1)
    ramp2 = FieldRamp(start = a2, stop = b2, n = n2)
    ramp3 = FieldRamp(start = a3, stop = b3, n = n3)
    ramp4 = FieldRamp(start = a4, stop = b4, n = n4)
    gamma_ramp = GammaRamp(start = PARAMS.γ, stop = GAMMA_END, n = n2)
    stage1 = @CompositeAlgorithm begin
        @context c = core()
        @alias ramp1 = ramp1
        ramp1(E = c.integ.E)
    end
    stage2 = @CompositeAlgorithm begin
        @context c = core()
        @alias ramp2 = ramp2
        ramp2(E = c.integ.E)
        @alias gamma = gamma_ramp
        gamma(par = c.integ.par, stale = c.integ.stale)
    end
    stage3 = @CompositeAlgorithm begin
        @context c = core()
        @alias ramp3 = ramp3
        ramp3(E = c.integ.E)
    end
    stage4 = @CompositeAlgorithm begin
        @context c = core()
        @alias ramp4 = ramp4
        ramp4(E = c.integ.E)
    end
    experiment = @Routine begin
        @repeat n1 stage1()
        @repeat n2 stage2()
        @repeat n3 stage3()
        @repeat n4 stage4()
    end
    return experiment, integ
end

framework_setup(Emax) = (experiment_integ = framework_experiment(Emax); (; ip = InlineProcess(experiment_integ[1], Init(experiment_integ[2]; u0 = U0, par = PARAMS); repeats = 1), integ = experiment_integ[2]))
framework_go!(s) = (run(s.ip); nothing)
function framework_result(s)
    c = context(s.ip)
    return (copy(c[s.integ].u), c[s.integ].t, copy(c[Polarization].trace), copy(c[FieldLoop].pairs))
end
