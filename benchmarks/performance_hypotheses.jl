#!/usr/bin/env julia

# Standalone performance probes for semantics-preserving optimization work.
#
# Run from the repository root:
#
#   julia --project=. benchmarks/performance_hypotheses.jl
#
# Optional knobs:
#
#   PROCESSES_BENCH_TRIALS=10
#   PROCESSES_BENCH_REPEATS=1000000
#   PROCESSES_BENCH_CONSTRUCTION_TRIALS=1000
#   PROCESSES_BENCH_LLVM=1
#
# The benchmarks intentionally avoid BenchmarkTools so they can run from the
# package project without adding another benchmark environment. They are meant
# as quick hypothesis probes, not final statistically rigorous numbers.

using InteractiveUtils
using Printf
using Statistics

using StatefulAlgorithms

const TRIALS = parse(Int, get(ENV, "PROCESSES_BENCH_TRIALS", "5"))
const REPEATS = parse(Int, get(ENV, "PROCESSES_BENCH_REPEATS", "200000"))
const CONSTRUCTION_TRIALS = parse(Int, get(ENV, "PROCESSES_BENCH_CONSTRUCTION_TRIALS", "200"))
const PRINT_LLVM = get(ENV, "PROCESSES_BENCH_LLVM", "0") == "1"

struct BenchSource <: StatefulAlgorithms.ProcessAlgorithm end
struct BenchStableSink <: StatefulAlgorithms.ProcessAlgorithm end
struct BenchLateSink <: StatefulAlgorithms.ProcessAlgorithm end

function StatefulAlgorithms.init(::BenchSource, context)
    return (; tick = 0, scale = context.scale, source = 0.0)
end

function StatefulAlgorithms.init(::BenchStableSink, _context)
    return (; tick = 0, accum = 0.0, derived = 0.0)
end

function StatefulAlgorithms.init(::BenchLateSink, _context)
    return (; tick = 0, accum = 0.0)
end

function StatefulAlgorithms.step!(::BenchSource, context::C) where {C}
    tick = context.tick + 1
    source = muladd(context.scale, tick, context.source)
    return (; tick, source)
end

function StatefulAlgorithms.step!(::BenchStableSink, context::C) where {C}
    tick = context.tick + 1
    derived = muladd(0.5, context.input_source, 0.001 * tick)
    accum = context.accum + derived
    return (; tick, accum, derived)
end

function StatefulAlgorithms.step!(::BenchLateSink, context::C) where {C}
    tick = context.tick + 1
    derived = muladd(0.5, context.input_source, 0.001 * tick)
    accum = context.accum + derived
    return (; tick, accum, derived)
end

const StableRouteGraph = StatefulAlgorithms.CompositeAlgorithm(
    BenchSource,
    BenchStableSink,
    (1, 1),
    StatefulAlgorithms.Route(BenchSource => BenchStableSink, :source => :input_source),
)

const LateRouteGraph = StatefulAlgorithms.CompositeAlgorithm(
    BenchSource,
    BenchLateSink,
    (1, 1),
    StatefulAlgorithms.Route(BenchSource => BenchLateSink, :source => :input_source),
)

struct BenchFib <: StatefulAlgorithms.ProcessAlgorithm end
struct BenchLuc <: StatefulAlgorithms.ProcessAlgorithm end

function StatefulAlgorithms.init(::BenchFib, context)
    fib = Int[0, 1]
    StatefulAlgorithms.processsizehint!(fib, context)
    return (; fib)
end

function StatefulAlgorithms.init(::BenchLuc, context)
    luc = Int[2, 1]
    StatefulAlgorithms.processsizehint!(luc, context)
    return (; luc)
end

function StatefulAlgorithms.step!(::BenchFib, context::C) where {C}
    fib = context.fib
    push!(fib, fib[end] + fib[end - 1])
    return nothing
end

function StatefulAlgorithms.step!(::BenchLuc, context::C) where {C}
    luc = context.luc
    push!(luc, luc[end] + luc[end - 1])
    return nothing
end

const FibLucGraph = StatefulAlgorithms.CompositeAlgorithm(BenchFib, BenchLuc, (1, 1))

function summarize(label, times, allocs)
    sorted_times = sort(times)
    sorted_allocs = sort(allocs)
    @printf(
        "%-34s best %9.6f s   median %9.6f s   alloc median %10d bytes\n",
        label,
        first(sorted_times),
        median(sorted_times),
        round(Int, median(sorted_allocs)),
    )
    return nothing
end

function sample(label, f; trials = TRIALS, gc = true)
    f()
    gc && GC.gc()

    times = Float64[]
    allocs = Int[]
    for _ in 1:trials
        gc && GC.gc()
        push!(times, @elapsed f())
        push!(allocs, @allocated f())
    end
    summarize(label, times, allocs)
    return (; label, times, allocs)
end

function run_process_graph(algo; repeats = REPEATS)
    p = StatefulAlgorithms.Process(
        algo,
        StatefulAlgorithms.Input(BenchSource; scale = 0.001);
        repeats,
    )
    StatefulAlgorithms.run(p)
    wait(p)
    result = fetch(p)
    StatefulAlgorithms.quit(p)
    return result
end

function construct_and_quit_process(algo)
    p = StatefulAlgorithms.Process(
        algo,
        StatefulAlgorithms.Input(BenchSource; scale = 0.001);
        repeats = 1,
    )
    StatefulAlgorithms.quit(p)
    return nothing
end

function stable_step_probe(algo)
    ip = StatefulAlgorithms.InlineProcess(
        algo,
        StatefulAlgorithms.Input(BenchSource; scale = 0.001);
        repeats = 1,
    )
    runtime_context = StatefulAlgorithms._merge_into_globals(StatefulAlgorithms.context(ip), (; process = ip))
    graph = StatefulAlgorithms.getalgo(StatefulAlgorithms.taskdata(ip))
    boot_context = StatefulAlgorithms.step!(graph, runtime_context)
    return graph, boot_context
end

function direct_stable_step_alloc(algo)
    graph, boot_context = stable_step_probe(algo)
    return @allocated StatefulAlgorithms.step!(graph, boot_context)
end

function run_inline_default(ip)
    StatefulAlgorithms.reset!(ip)
    return run(ip)
end

function run_inline_nongenerated(ip)
    StatefulAlgorithms.reset!(ip)
    return StatefulAlgorithms.run_nogen(ip)
end

function run_inline_generated(ip)
    StatefulAlgorithms.reset!(ip)
    graph = StatefulAlgorithms.getalgo(StatefulAlgorithms.taskdata(ip))
    runtime_context = StatefulAlgorithms._merge_into_globals(StatefulAlgorithms.context(ip), (; process = ip))
    return StatefulAlgorithms.loop(ip, graph, runtime_context, StatefulAlgorithms.lifetime(ip), StatefulAlgorithms.Generated())
end

function naive_fibluc(n)
    fib = Int[0, 1]
    luc = Int[2, 1]
    sizehint!(fib, n + 2)
    sizehint!(luc, n + 2)
    for _ in 1:n
        push!(fib, fib[end] + fib[end - 1])
        push!(luc, luc[end] + luc[end - 1])
    end
    return fib[end] + luc[end]
end

function print_llvm_probe()
    graph, boot_context = stable_step_probe(StableRouteGraph)
    println()
    println("LLVM for one stable routed CompositeAlgorithm step:")
    code_llvm(
        stdout,
        StatefulAlgorithms.step!,
        Tuple{typeof(graph), typeof(boot_context)};
        debuginfo = :none,
        optimize = true,
    )
    return nothing
end

function main()
    println("StatefulAlgorithms.jl performance hypothesis probes")
    println("trials: ", TRIALS)
    println("repeats: ", REPEATS)
    println("construction trials: ", CONSTRUCTION_TRIALS)
    println()

    sample("Process construct+quit stable", () -> construct_and_quit_process(StableRouteGraph); trials = CONSTRUCTION_TRIALS)
    sample("Process construct+quit late", () -> construct_and_quit_process(LateRouteGraph); trials = CONSTRUCTION_TRIALS)
    println()

    stable_alloc = direct_stable_step_alloc(StableRouteGraph)
    late_alloc = direct_stable_step_alloc(LateRouteGraph)
    println("Direct post-bootstrap stable step allocation probes:")
    println("  StableRouteGraph: ", stable_alloc, " bytes")
    println("  LateRouteGraph:   ", late_alloc, " bytes")
    println()

    sample("Process run stable routed", () -> run_process_graph(StableRouteGraph))
    sample("Process run late-growth routed", () -> run_process_graph(LateRouteGraph))
    println()

    ip_default = StatefulAlgorithms.InlineProcess(FibLucGraph; repeats = REPEATS)
    ip_nogen = StatefulAlgorithms.InlineProcess(FibLucGraph; repeats = REPEATS)
    ip_gen = StatefulAlgorithms.InlineProcess(FibLucGraph; repeats = REPEATS)

    sample("InlineProcess default", () -> run_inline_default(ip_default))
    sample("InlineProcess NonGenerated", () -> run_inline_nongenerated(ip_nogen))
    sample("InlineProcess Generated", () -> run_inline_generated(ip_gen))
    sample("Naive fib/luc loop", () -> naive_fibluc(REPEATS))

    PRINT_LLVM && print_llvm_probe()
    return nothing
end

main()
