# Experiments on the StatefulAlgorithms backend: stateful steps composed with the physics.
#
#   E1 Controller  PI controller holding coverage at a target by adjusting `feed`   (private integrator)
#   E2 Recorder    ring buffer of (t, mean V, coverage, feed)                       (private buffer)
#   E4 Probe       kicks the field, tracks how far it drifts from the pre-kick state (private state machine)
#   E3 sweep       a @Routine that ramps feed up and down, relaxing at each value    (nested schedule)
#
# Lines between `#>>` and `#<<` markers (or ending in `#>> Ek`) are what each experiment costs;
# experiments/compare.jl counts them.

include(joinpath(@__DIR__, "..", "..", "gray_scott_definitions.jl"))
include(joinpath(@__DIR__, "..", "common.jl"))

#>> E1 controller
@StepAlgorithm begin
    @config target::Float32 = 0.55f0
    @config kp::Float32 = 0.02f0
    @config ki::Float32 = 0.00005f0
    function Controller(V, feed, @managed(integral = 0f0))
        newfeed, integral = controller_action(interior(V), integral, target, kp, ki)
        return (; feed = newfeed, integral)
    end
end
#<< E1

#>> E2 recorder
@StepAlgorithm begin
    @config capacity::Int = 64
    function Recorder(V, feed, steps, @managed(buf = zeros(Float32, 4, capacity), head = 0, count = 0))
        head = head % capacity + 1
        Vi = interior(V)
        buf[:, head] .= (steps[], meanv(Vi), coverage(Vi), feed)
        return (; head, count = min(count + 1, capacity))
    end
end
#<< E2

#>> E4 probe
@StepAlgorithm begin
    @config n::Int = 64
    @config every::Int = 40
    @config radius::Float32 = 4f0
    function Probe(U, V, @managed(base = zeros(Float32, n, n), rng = Random.Xoshiro(7), calls = 0,
                                  kicks = 0, peak = 0f0, last = 0f0, results = Tuple{Int,Float32,Float32}[]))
        calls, kicks, peak, last = probe_action!(interior(U), interior(V), base, rng, calls, every, radius,
                                                 kicks, peak, last, results)
        return (; calls, kicks, peak, last)
    end
end
#<< E4

function experiments_algorithm(n, feed, kill)
    return @CompositeAlgorithm begin
        @state sim begin
            feed = feed
            kill = kill
            pairs = 1
            U = ones(Float32, n + 2, n + 2)
            V = zeros(Float32, n + 2, n + 2)
            U2 = ones(Float32, n + 2, n + 2)
            V2 = zeros(Float32, n + 2, n + 2)
            steps = Ref(0)
        end

        GrayScott(U, V, U2, V2, feed, kill, pairs, steps)
        @interval 20 Controller(V, feed)               #>> E1
        @interval 25 Recorder(V, feed, steps)          #>> E2
        @interval 25 Probe(U, V)                       #>> E4
    end
end

function run_experiments(n, niter; seed = 1)
    p = Process(resolve(experiments_algorithm(n, 0.037f0, 0.06f0)); repeats = niter)
    st = context(p).sim
    Random.seed!(seed); seed_blobs!(interior(st.U), interior(st.V))
    run(p); wait(p)
    ctx = context(p)
    return (; V = copy(interior(ctx.sim.V)), feed = ctx.sim.feed, steps = ctx.sim.steps[],
              rec = copy(ctx.Recorder_1.buf), rec_head = ctx.Recorder_1.head, probe = copy(ctx.Probe_1.results),
              integral = ctx.Controller_1.integral)
end

#>> E3 sweep
@StepAlgorithm begin
    @config lo::Float32 = 0.030f0
    @config hi::Float32 = 0.050f0
    @config np::Int = 5
    function SetFeed(feed, @managed(i = 0))
        i += 1
        return (; feed = ramp_value(i, lo, hi, np), i)
    end
end

@StepAlgorithm function Measure(V, feed, @managed(curve = Tuple{Float32,Float32}[]))
    push!(curve, (feed, coverage(interior(V))))
    return (;)
end

function sweep_algorithm(n, kill, nrelax)
    return @Routine begin
        @state sim begin
            feed = 0.03f0
            kill = kill
            pairs = 1
            U = ones(Float32, n + 2, n + 2)
            V = zeros(Float32, n + 2, n + 2)
            U2 = ones(Float32, n + 2, n + 2)
            V2 = zeros(Float32, n + 2, n + 2)
            steps = Ref(0)
        end

        SetFeed(feed)
        @repeat nrelax GrayScott(U, V, U2, V2, feed, kill, pairs, steps)
        Measure(V, feed)
    end
end
#<< E3

function run_sweep(n, nrelax; np = 5, seed = 1)
    p = Process(resolve(sweep_algorithm(n, 0.06f0, nrelax)); repeats = 2np)
    st = context(p).sim
    Random.seed!(seed); seed_blobs!(interior(st.U), interior(st.V))
    run(p); wait(p)
    return copy(context(p).Measure_1.curve)
end
