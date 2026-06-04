include("_env.jl")
using Random

"""
Manual benchmark for a genuinely nontrivial DAG.

Graph:
- SourceX -> StageA, StageB
- SourceY -> StageC
- StageA + StageC -> JoinD
- StageB + StageC -> JoinE
- StageA + JoinE -> StageF
- JoinD + JoinE -> StageG
- StageB + JoinD -> StageH
- StageF + StageG + StageH -> Reducer

The key difference from the earlier benchmarks is that this graph has:
- two independent roots,
- multiple internal joins,
- reused intermediates feeding different downstream nodes.

We benchmark the same routed graph against:
- CompositeAlgorithm
- ThreadedCompositeAlgorithm
"""

struct SourceXBench <: StatefulAlgorithms.ProcessAlgorithm end
struct SourceYBench <: StatefulAlgorithms.ProcessAlgorithm end
struct StageABench <: StatefulAlgorithms.ProcessAlgorithm end
struct StageBBench <: StatefulAlgorithms.ProcessAlgorithm end
struct StageCBench <: StatefulAlgorithms.ProcessAlgorithm end
struct JoinDBench <: StatefulAlgorithms.ProcessAlgorithm end
struct JoinEBench <: StatefulAlgorithms.ProcessAlgorithm end
struct StageFBench <: StatefulAlgorithms.ProcessAlgorithm end
struct StageGBench <: StatefulAlgorithms.ProcessAlgorithm end
struct StageHBench <: StatefulAlgorithms.ProcessAlgorithm end
struct ReducerBench <: StatefulAlgorithms.ProcessAlgorithm end

function StatefulAlgorithms.init(::SourceXBench, context)
    return (; x_signal = copy(context.start_x), phase_x = 0.01)
end

function StatefulAlgorithms.init(::SourceYBench, context)
    return (; y_signal = copy(context.start_y), phase_y = 0.015)
end

function StatefulAlgorithms.step!(::SourceXBench, context)
    x_signal = context.x_signal
    phase_x = context.phase_x

    @inbounds for i in eachindex(x_signal)
        x = x_signal[i]
        x_signal[i] = sin(x + phase_x) + cos(0.25 * x - phase_x) + 0.0000004 * i
    end

    return (; phase_x = phase_x + 0.01)
end

function StatefulAlgorithms.step!(::SourceYBench, context)
    y_signal = context.y_signal
    phase_y = context.phase_y

    @inbounds for i in eachindex(y_signal)
        y = y_signal[i]
        y_signal[i] = cos(y + phase_y) + tanh(0.5 * y - phase_y) + 0.0000003 * i
    end

    return (; phase_y = phase_y + 0.015)
end

StatefulAlgorithms.init(::StageABench, context) = (; a_vec = zeros(context.n))
StatefulAlgorithms.init(::StageBBench, context) = (; b_vec = zeros(context.n))
StatefulAlgorithms.init(::StageCBench, context) = (; c_vec = zeros(context.n))
StatefulAlgorithms.init(::JoinDBench, context) = (; d_vec = zeros(context.n))
StatefulAlgorithms.init(::JoinEBench, context) = (; e_vec = zeros(context.n))
StatefulAlgorithms.init(::StageFBench, context) = (; f_vec = zeros(context.n))
StatefulAlgorithms.init(::StageGBench, context) = (; g_vec = zeros(context.n))
StatefulAlgorithms.init(::StageHBench, context) = (; h_vec = zeros(context.n))
StatefulAlgorithms.init(::ReducerBench, _context) = (; total = 0.0)

function StatefulAlgorithms.step!(::StageABench, context)
    x = context.x_input
    y = context.a_vec

    @inbounds for i in eachindex(y)
        xi = x[i]
        y[i] = sin(xi) + sqrt(abs(xi) + 1)
    end

    return (;)
end

function StatefulAlgorithms.step!(::StageBBench, context)
    x = context.x_input
    y = context.b_vec

    @inbounds for i in eachindex(y)
        xi = x[i]
        y[i] = cos(xi) + abs(xi)
    end

    return (;)
end

function StatefulAlgorithms.step!(::StageCBench, context)
    x = context.y_input
    y = context.c_vec

    @inbounds for i in eachindex(y)
        xi = x[i]
        y[i] = exp(-abs(xi)) + 0.001 * xi * xi
    end

    return (;)
end

function StatefulAlgorithms.step!(::JoinDBench, context)
    a = context.a
    c = context.c
    y = context.d_vec

    @inbounds for i in eachindex(y)
        ai = a[i]
        ci = c[i]
        y[i] = muladd(0.7, ai, 0.3 * ci) + sin(ai - ci)
    end

    return (;)
end

function StatefulAlgorithms.step!(::JoinEBench, context)
    b = context.b
    c = context.c
    y = context.e_vec

    @inbounds for i in eachindex(y)
        bi = b[i]
        ci = c[i]
        y[i] = 0.5 * bi + 0.5 * ci + cos(bi + ci)
    end

    return (;)
end

function StatefulAlgorithms.step!(::StageFBench, context)
    a = context.a
    e = context.e
    y = context.f_vec

    @inbounds for i in eachindex(y)
        ai = a[i]
        ei = e[i]
        y[i] = tanh(ai + ei) + 0.1 * (ai - ei)
    end

    return (;)
end

function StatefulAlgorithms.step!(::StageGBench, context)
    d = context.d
    e = context.e
    y = context.g_vec

    @inbounds for i in eachindex(y)
        di = d[i]
        ei = e[i]
        y[i] = sqrt(abs(di * ei) + 1) + sin(di) - cos(ei)
    end

    return (;)
end

function StatefulAlgorithms.step!(::StageHBench, context)
    b = context.b
    d = context.d
    y = context.h_vec

    @inbounds for i in eachindex(y)
        bi = b[i]
        di = d[i]
        y[i] = exp(-abs(bi - di)) + 0.05 * (bi + di)
    end

    return (;)
end

function StatefulAlgorithms.step!(::ReducerBench, context)
    f = context.f
    g = context.g
    h = context.h

    total = 0.0
    @inbounds for i in eachindex(f)
        fi = f[i]
        gi = g[i]
        hi = h[i]
        total += fi + gi + hi + 0.1 * fi * gi
    end

    return (; total)
end

function build_algorithms()
    routes = (
        Route(SourceXBench => StageABench, :x_signal => :x_input),
        Route(SourceXBench => StageBBench, :x_signal => :x_input),
        Route(SourceYBench => StageCBench, :y_signal => :y_input),

        Route(StageABench => JoinDBench, :a_vec => :a),
        Route(StageCBench => JoinDBench, :c_vec => :c),

        Route(StageBBench => JoinEBench, :b_vec => :b),
        Route(StageCBench => JoinEBench, :c_vec => :c),

        Route(StageABench => StageFBench, :a_vec => :a),
        Route(JoinEBench => StageFBench, :e_vec => :e),

        Route(JoinDBench => StageGBench, :d_vec => :d),
        Route(JoinEBench => StageGBench, :e_vec => :e),

        Route(StageBBench => StageHBench, :b_vec => :b),
        Route(JoinDBench => StageHBench, :d_vec => :d),

        Route(StageFBench => ReducerBench, :f_vec => :f),
        Route(StageGBench => ReducerBench, :g_vec => :g),
        Route(StageHBench => ReducerBench, :h_vec => :h),
    )

    funcs = (
        SourceXBench, SourceYBench,
        StageABench, StageBBench, StageCBench,
        JoinDBench, JoinEBench,
        StageFBench, StageGBench, StageHBench,
        ReducerBench,
    )

    intervals = ntuple(_ -> 1, length(funcs))

    comp = CompositeAlgorithm(funcs..., intervals, routes...)
    threaded = ThreadedCompositeAlgorithm(funcs..., intervals, routes...)

    return comp, threaded
end

function run_once(algo, start_x, start_y; repeats)
    n = length(start_x)
    p = Process(
        algo,
        Input(SourceXBench, :start_x => copy(start_x)),
        Input(SourceYBench, :start_y => copy(start_y)),
        Input(StageABench; n),
        Input(StageBBench; n),
        Input(StageCBench; n),
        Input(JoinDBench; n),
        Input(JoinEBench; n),
        Input(StageFBench; n),
        Input(StageGBench; n),
        Input(StageHBench; n);
        lifetime = repeats,
    )

    elapsed = @elapsed begin
        run(p)
        wait(p)
    end

    ctx = fetch(p)
    quit(p)

    return elapsed, ctx
end

function benchmark(algo, start_x, start_y; repeats, trials, label)
    times = Float64[]
    final_ctx = nothing

    run_once(algo, start_x, start_y; repeats = 1)
    GC.gc()

    for trial in 1:trials
        elapsed, ctx = run_once(algo, start_x, start_y; repeats)
        push!(times, elapsed)
        final_ctx = ctx
        GC.gc()
        println(label, " trial ", trial, ": ", round(elapsed; digits = 4), " s")
    end

    return times, final_ctx
end

function main()
    Random.seed!(1234)

    n = 250_000
    repeats = 6
    trials = 3
    start_x = randn(n)
    start_y = randn(n)

    comp, threaded = build_algorithms()

    println("Signal length: ", n)
    println("Repeats: ", repeats)
    println("Trials: ", trials)
    println("Pattern: two roots -> overlapping joins -> reused intermediates -> reducer")
    println()

    comp_times, comp_ctx = benchmark(comp, start_x, start_y; repeats, trials, label = "Composite")
    println()
    threaded_times, threaded_ctx = benchmark(threaded, start_x, start_y; repeats, trials, label = "Threaded")
    println()
    for ctx in (threaded_ctx,)
        @assert isapprox(comp_ctx[SourceXBench].x_signal, ctx[SourceXBench].x_signal; rtol = 0.0, atol = 1e-10)
        @assert isapprox(comp_ctx[SourceYBench].y_signal, ctx[SourceYBench].y_signal; rtol = 0.0, atol = 1e-10)
        @assert isapprox(comp_ctx[StageABench].a_vec, ctx[StageABench].a_vec; rtol = 0.0, atol = 1e-10)
        @assert isapprox(comp_ctx[StageBBench].b_vec, ctx[StageBBench].b_vec; rtol = 0.0, atol = 1e-10)
        @assert isapprox(comp_ctx[StageCBench].c_vec, ctx[StageCBench].c_vec; rtol = 0.0, atol = 1e-10)
        @assert isapprox(comp_ctx[JoinDBench].d_vec, ctx[JoinDBench].d_vec; rtol = 0.0, atol = 1e-10)
        @assert isapprox(comp_ctx[JoinEBench].e_vec, ctx[JoinEBench].e_vec; rtol = 0.0, atol = 1e-10)
        @assert isapprox(comp_ctx[StageFBench].f_vec, ctx[StageFBench].f_vec; rtol = 0.0, atol = 1e-10)
        @assert isapprox(comp_ctx[StageGBench].g_vec, ctx[StageGBench].g_vec; rtol = 0.0, atol = 1e-10)
        @assert isapprox(comp_ctx[StageHBench].h_vec, ctx[StageHBench].h_vec; rtol = 0.0, atol = 1e-10)
        @assert isapprox(comp_ctx[ReducerBench].total, ctx[ReducerBench].total; rtol = 0.0, atol = 1e-8)
    end

    comp_best = minimum(comp_times)
    threaded_best = minimum(threaded_times)

    println("Composite best: ", round(comp_best; digits = 4), " s")
    println("Threaded best: ", round(threaded_best; digits = 4), " s")
    println("Threaded / Composite: ", round(threaded_best / comp_best; digits = 3), "x")
    println("Final total: ", round(comp_ctx[ReducerBench].total; digits = 6))
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
