# The same experiments on the bespoke backend, written the way I would write them by hand: the
# experiment state goes into a struct that wraps the base `Sim`, the loop calls the experiments on
# their schedule, and each experiment is a function over that struct.
#
#   E1 controller!   PI controller holding coverage at a target by adjusting `feed`
#   E2 recorder!     ring buffer of (t, mean V, coverage, feed)
#   E4 probe!        kicks the field, tracks how far it drifts from the pre-kick state
#   E3 sweep!        feed ramps up and down, relaxing at each value (plain nested loops)
#
# Lines between `#>>` and `#<<` markers (or ending in `#>> Ek`) are what each experiment costs;
# experiments/compare.jl counts them.

include(joinpath(@__DIR__, "..", "..", "gray_scott_bespoke.jl"))
include(joinpath(@__DIR__, "..", "common.jl"))

mutable struct ExpSim
    sim::Sim                                  # buffers, controls, steps counter (the base backend)
    iter::Int                                 # iteration counter, drives every schedule below
    #>> E1 controller
    integral::Float32
    #<< E1
    #>> E2 recorder
    buf::Matrix{Float32}
    head::Int
    count::Int
    #<< E2
    #>> E4 probe
    base::Matrix{Float32}
    rng::Xoshiro
    calls::Int
    kicks::Int
    peak::Float32
    last::Float32
    results::Vector{Tuple{Int,Float32,Float32}}
    #<< E4
end

function ExpSim(n; feed = 0.037f0, kill = 0.060f0)
    return ExpSim(Sim(n; feed, kill), 0,
        0f0,                                                                          #>> E1
        zeros(Float32, 4, 64), 0, 0,                                                  #>> E2
        zeros(Float32, n, n), Xoshiro(7), 0, 0, 0f0, 0f0, Tuple{Int,Float32,Float32}[])   #>> E4
end

#>> E1 controller
function controller!(e::ExpSim; target = 0.55f0, kp = 0.02f0, ki = 0.00005f0)
    newfeed, e.integral = controller_action(interior(e.sim.V), e.integral, target, kp, ki)
    e.sim.feed[] = newfeed
end
#<< E1

#>> E2 recorder
function recorder!(e::ExpSim)
    e.head = e.head % size(e.buf, 2) + 1
    Vi = interior(e.sim.V)
    e.buf[:, e.head] .= (e.sim.steps[], meanv(Vi), coverage(Vi), e.sim.feed[])
    e.count = min(e.count + 1, size(e.buf, 2))
end
#<< E2

#>> E4 probe
function probe!(e::ExpSim; every = 40, radius = 4f0)
    e.calls, e.kicks, e.peak, e.last = probe_action!(interior(e.sim.U), interior(e.sim.V), e.base, e.rng,
        e.calls, every, radius, e.kicks, e.peak, e.last, e.results)
end
#<< E4

function exp_loop!(e::ExpSim, niter)
    for _ in 1:niter
        loop!(e.sim, 1)                                     # one physics iteration (base loop)
        e.iter += 1
        e.iter % 20 == 0 && controller!(e)                  #>> E1
        e.iter % 25 == 0 && recorder!(e)                    #>> E2
        e.iter % 25 == 0 && probe!(e)                       #>> E4
    end
end

function run_experiments(n, niter; seed = 1)
    e = ExpSim(n)
    Random.seed!(seed); seed_blobs!(interior(e.sim.U), interior(e.sim.V))
    exp_loop!(e, niter)
    return (; V = copy(interior(e.sim.V)), feed = e.sim.feed[], steps = e.sim.steps[],
              rec = copy(e.buf), rec_head = e.head, probe = copy(e.results), integral = e.integral)
end

#>> E3 sweep
function sweep!(s::Sim, lo, hi, np, nrelax)
    curve = Tuple{Float32,Float32}[]
    for i in 1:2np
        s.feed[] = ramp_value(i, lo, hi, np)
        loop!(s, nrelax)                                    # relax: nrelax physics iterations
        push!(curve, (s.feed[], coverage(interior(s.V))))
    end
    return curve
end
#<< E3

function run_sweep(n, nrelax; np = 5, seed = 1)
    s = Sim(n; feed = 0.03f0, kill = 0.06f0)
    Random.seed!(seed); seed_blobs!(interior(s.U), interior(s.V))
    return sweep!(s, 0.030f0, 0.050f0, np, nrelax)
end
