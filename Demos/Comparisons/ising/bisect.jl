# Where does the framework's per-step cost come from? One algorithm, constant T, vary the wrapper.
using Printf, Random, StatefulAlgorithms
include(joinpath(@__DIR__, "kernel.jl"))
@StepAlgorithm function MetroC(@managed(spins = fresh_spins()), @managed(rng = Xoshiro(1)), @managed(m = 0))
    m += flip!(spins, rng, 2.0, 0.0)
    return (; m)
end
@noinline function hand_loop(spins, rng, N)
    m = 0
    for _ in 1:N; m += flip!(spins, rng, 2.0, 0.0); end
    return m
end
mutable struct Counter; loopidx::UInt; end
@noinline function hand_counter_loop(spins, rng, c, N)
    m = 0
    for _ in 1:N
        m += flip!(spins, rng, 2.0, 0.0)
        c.loopidx += one(UInt)            # what inc!(process) does every iteration
    end
    return m
end
hand_counter(N) = (s = fresh_spins(); r = Xoshiro(1); (hand_counter_loop(s, r, Counter(1), N), sum(s)))
hand(N) = (s = fresh_spins(); r = Xoshiro(1); (hand_loop(s, r, N), sum(s)))
function viaplan(plan)
    return function (N)
        ip = InlineProcess(plan; repeats = N); run(ip); c = context(ip)
        (c[MetroC].m, sum(c[MetroC].spins))
    end
end
variants = ["hand loop, state from caller" => hand,
            "hand loop + heap counter (inc!-like)" => hand_counter,
            "InlineProcess(MetroC)" => viaplan(MetroC),
            "CompositeAlgorithm(MetroC, (1,))" => viaplan(CompositeAlgorithm(MetroC, (1,))),
            "Routine(MetroC, (1,))" => viaplan(Routine(MetroC, (1,)))]
N = 20_000_000
for (_, f) in variants; f(2000); end
res = [f(N) for (_, f) in variants]; println(all(==(res[1]), res) ? "identical" : "DIFFER: $res")
wall = [Float64[] for _ in variants]
for _ in 1:7, (k, (_, f)) in enumerate(variants); GC.gc(false); push!(wall[k], @elapsed f(N)); end
for (k, (n, _)) in enumerate(variants); @printf("%-34s %.2f ns/step\n", n, minimum(wall[k]) / N * 1e9); end
