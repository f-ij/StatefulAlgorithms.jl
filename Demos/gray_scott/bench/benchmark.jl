# Gray-Scott: StatefulAlgorithms demo vs bespoke demo. Both expose the same control surface (live
# params, edit queue, pause/resume, readable buffers), so gray_scott.jl runs on either.
#
#   julia -t 1 --project=Demos/gray_scott Demos/gray_scott/bench/benchmark.jl
#   GS_SIZES=16,256 GS_PAIRS=1,8 ...      to pick sizes / ping-pong pairs per iteration
#
# Every variant runs the same arithmetic from the same seeded state for the same number of substeps:
#
#   kernel bare     the sweep in a plain loop: the floor, nothing around it
#   SA minimal      a Process with only the GrayScott step
#   SA demo         gray_scott_definitions.jl: Edit + GrayScott + Pace (the full control surface)
#   bespoke demo    gray_scott_bespoke.jl: hand-written loop task with the same control surface
#
# Method: variants interleaved round-robin over ROUNDS rounds, minimum per variant reported.

using StatefulAlgorithms
using Random, Printf

include(joinpath(@__DIR__, "..", "gray_scott_definitions.jl"))               # SA demo, in Main
module Bespoke; include(joinpath(@__DIR__, "..", "gray_scott_bespoke.jl")); end   # bespoke, own namespace

const ROUNDS = 7
const SIZES = parse.(Int, split(get(ENV, "GS_SIZES", "16,64,256,512"), ","))
const PAIRS = parse.(Int, split(get(ENV, "GS_PAIRS", "1"), ","))
const FEED, KILL = 0.037f0, 0.060f0

function seeded(n)
    U = ones(Float32, n, n); V = zeros(Float32, n, n)
    Random.seed!(1); seed_blobs!(U, V)
    return U, V
end

function padded_state(n)
    U0, V0 = seeded(n)
    U = ones(Float32, n + 2, n + 2); V = zeros(Float32, n + 2, n + 2)
    interior(U) .= U0; interior(V) .= V0
    return U, V, copy(U), copy(V)
end

# ── variants: each takes (n, substeps, pairs), returns the final V ──────────────────────────
function run_kernel(n, nsub, pairs)
    U, V, U2, V2 = padded_state(n)
    for _ in 1:(nsub ÷ 2)
        substep!(U2, V2, U, V, 1f0, 0.5f0, FEED, KILL, 1f0)
        substep!(U, V, U2, V2, 1f0, 0.5f0, FEED, KILL, 1f0)
    end
    return copy(interior(V))
end

function run_process(algo, n, nsub, pairs)
    p = Process(resolve(algo), Interactive(:sim, :feed, :kill, :pairs, :period); repeats = nsub ÷ (2pairs))
    st = context(p).sim
    U0, V0 = seeded(n)
    interior(st.U) .= U0; interior(st.V) .= V0
    st.pairs[] = pairs
    run(p); wait(p)
    return copy(interior(st.V))
end

sa_demo(n, nsub, pairs) = run_process(gray_scott_algorithm(n, FEED, KILL), n, nsub, pairs)

sa_minimal(n, nsub, pairs) = run_process(
    @CompositeAlgorithm(begin
        @state sim begin
            feed = FEED
            kill = KILL
            pairs = 1
            period = 0f0
            U = ones(Float32, n + 2, n + 2)
            V = zeros(Float32, n + 2, n + 2)
            U2 = ones(Float32, n + 2, n + 2)
            V2 = zeros(Float32, n + 2, n + 2)
            steps = Ref(0)
        end
        GrayScott(U, V, U2, V2, feed, kill, pairs, steps)
    end), n, nsub, pairs)

function bespoke_demo(n, nsub, pairs)
    B = Bespoke
    s = B.Sim(ones(Float32, n + 2, n + 2), zeros(Float32, n + 2, n + 2),
              ones(Float32, n + 2, n + 2), zeros(Float32, n + 2, n + 2),
              Ref(FEED), Ref(KILL), Ref(pairs), Ref(0f0), Ref(0), Channel{Function}(256), false, nothing)
    U0, V0 = seeded(n)
    interior(s.U) .= U0; interior(s.V) .= V0
    fetch(Threads.@spawn B.loop!(s, nsub ÷ (2pairs)))                 # a task, like the Process
    return copy(interior(s.V))
end

const VARIANTS = [
    ("kernel bare",  run_kernel),
    ("SA minimal",   sa_minimal),
    ("SA demo",      sa_demo),
    ("bespoke demo", bespoke_demo),
]

# ── harness ─────────────────────────────────────────────────────────────────────────────────
function timed(f, args...)
    GC.gc()
    t0 = time_ns()
    f(args...)
    return (time_ns() - t0) / 1e9
end

function bench(n, pairs; target_cells = 8e7)
    nsub = max(2, 2 * round(Int, target_cells / n^2 / 2))
    best = Dict(name => Inf for (name, _) in VARIANTS)
    for (_, f) in VARIANTS; f(n, 2, pairs); end                       # compile, untimed
    for _ in 1:ROUNDS, (name, f) in VARIANTS                          # interleaved round-robin
        best[name] = min(best[name], timed(f, n, nsub, pairs))
    end
    return nsub, best
end

function validate(n)
    ref = run_kernel(n, 200, 1)
    for (name, f) in VARIANTS
        @printf("  max |V - kernel bare| after 200 substeps, %-14s %.2e\n", name, maximum(abs, f(n, 200, 1) .- ref))
    end
end

function main()
    Threads.nthreads() == 1 || @warn "benchmark assumed -t 1; found $(Threads.nthreads()) threads"
    println("load before: ", strip(read(`uptime`, String)))
    println("\nvalidation (same maths?), n = 128")
    validate(128)
    for pairs in PAIRS, n in SIZES
        nsub, best = bench(n, pairs)
        println("\nn = $n, $nsub substeps ($(nsub ÷ (2pairs)) iterations of $pairs ping-pong pair(s)), min of $ROUNDS")
        @printf("  %-14s %10s %14s %22s\n", "", "time [ms]", "substeps/s", "time vs bespoke demo")
        for (name, _) in VARIANTS
            t = best[name]
            @printf("  %-14s %10.2f %14.0f %12.3fx (%+.1f%%)\n", name, 1e3t, nsub / t, t / best["bespoke demo"], 100 * (t / best["bespoke demo"] - 1))
        end
    end
    println("\nload after:  ", strip(read(`uptime`, String)))
end

main()
