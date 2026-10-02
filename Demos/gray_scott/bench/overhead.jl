# What does the framework itself cost per iteration? Run single- or multi-threaded; the loop is one task.
#
#   julia --project=Demos/gray_scott Demos/gray_scott/bench/overhead.jl
#
# The kernel is taken out of the picture: steps do almost nothing, so any time is framework time.
# Each Process variant is compared with a bare loop doing the same work; difference / iterations.

using StatefulAlgorithms
using Printf

include(joinpath(@__DIR__, "..", "gray_scott_definitions.jl"))

const N = 3_000_000
const ROUNDS = 9

@StepAlgorithm function Tick(steps)
    steps[] += 1
    return (;)
end

@noinline bump!(r) = (r[] += 1; nothing)

function bare(k, iters)
    r = Ref(0)
    for _ in 1:iters, _ in 1:k; bump!(r); end
    return r[]
end

function proc_ticks(k, iters)
    algo = k == 1 ? (@CompositeAlgorithm begin
        @state sim begin; steps = Ref(0); end
        Tick(steps)
    end) : (@CompositeAlgorithm begin
        @state sim begin; steps = Ref(0); end
        Tick(steps); Tick(steps); Tick(steps); Tick(steps)
    end)
    return Process(resolve(algo); repeats = iters)
end

# the demo's own facility steps (Edit queue poll, Pace) on tiny arrays, no physics
function proc_facilities(iters)
    algo = @CompositeAlgorithm begin
        @state sim begin
            period = 0f0
            edits = Channel{Function}(256)
            U = ones(Float32, 4, 4)
            V = zeros(Float32, 4, 4)
        end
        Edit(edits, U, V)
        Pace(period)
    end
    return Process(resolve(algo); repeats = iters)
end

function timeit(f)
    GC.gc(); t0 = time_ns(); f(); return (time_ns() - t0) / 1e9
end
runp(p) = (run(p); wait(p))

cases = [
    ("1 trivial child",                   () -> runp(proc_ticks(1, N)),     () -> bare(1, N)),
    ("4 trivial children",                () -> runp(proc_ticks(4, N)),     () -> bare(4, N)),
    ("demo facilities (Edit,Pace)", () -> runp(proc_facilities(N)),  () -> bare(0, N)),
]
for (_, p, b) in cases; p(); b(); end                                   # compile
best = [(Inf, Inf) for _ in cases]
for _ in 1:ROUNDS, (i, (_, p, b)) in enumerate(cases)                   # interleaved
    best[i] = (min(best[i][1], timeit(p)), min(best[i][2], timeit(b)))
end
println("threads = ", Threads.nthreads(), ",  $N iterations, min of $ROUNDS, interleaved")
println("load: ", strip(read(`uptime`, String)))
@printf("  %-38s %12s %12s %14s\n", "", "process", "bare loop", "framework")
for ((name, _, _), (tp, tb)) in zip(cases, best)
    @printf("  %-38s %9.1f ns %9.1f ns %11.1f ns/it\n", name, 1e9tp / N, 1e9tb / N, 1e9 * (tp - tb) / N)
end
