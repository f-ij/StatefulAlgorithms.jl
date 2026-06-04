include("_env.jl")
using Random

"""
Manual benchmark that is actually merge-heavy.

Almost every node returns a full 8-field `NamedTuple` on every `step!`, so the hot path
is dominated by:
- local merge/writeback inside each step,
- routed multi-parent fill into downstream reduced views,
- final merge back into the full context.

Graph:
- SourceX -> A, B
- SourceY -> C, D
- SourceZ -> E, F
- A + C -> G
- B + D -> H
- C + E -> I
- D + F -> J
- G + H -> K
- H + I -> L
- I + J -> M
- K + L -> N
- L + M -> O
- N + O + G + J -> Reducer
"""

struct SourceXMerge <: StatefulAlgorithms.ProcessAlgorithm end
struct SourceYMerge <: StatefulAlgorithms.ProcessAlgorithm end
struct SourceZMerge <: StatefulAlgorithms.ProcessAlgorithm end

struct StageAMerge <: StatefulAlgorithms.ProcessAlgorithm end
struct StageBMerge <: StatefulAlgorithms.ProcessAlgorithm end
struct StageCMerge <: StatefulAlgorithms.ProcessAlgorithm end
struct StageDMerge <: StatefulAlgorithms.ProcessAlgorithm end
struct StageEMerge <: StatefulAlgorithms.ProcessAlgorithm end
struct StageFMerge <: StatefulAlgorithms.ProcessAlgorithm end

struct JoinGMerge <: StatefulAlgorithms.ProcessAlgorithm end
struct JoinHMerge <: StatefulAlgorithms.ProcessAlgorithm end
struct JoinIMerge <: StatefulAlgorithms.ProcessAlgorithm end
struct JoinJMerge <: StatefulAlgorithms.ProcessAlgorithm end
struct JoinKMerge <: StatefulAlgorithms.ProcessAlgorithm end
struct JoinLMerge <: StatefulAlgorithms.ProcessAlgorithm end
struct JoinMMerge <: StatefulAlgorithms.ProcessAlgorithm end
struct JoinNMerge <: StatefulAlgorithms.ProcessAlgorithm end
struct JoinOMerge <: StatefulAlgorithms.ProcessAlgorithm end

struct ReducerMerge <: StatefulAlgorithms.ProcessAlgorithm end

const MERGE_VALUE_NAMES = (:v1, :v2, :v3, :v4, :v5, :v6, :v7, :v8)

@inline _vals8(x::NTuple{8, Float64}) = (; v1 = x[1], v2 = x[2], v3 = x[3], v4 = x[4], v5 = x[5], v6 = x[6], v7 = x[7], v8 = x[8])
@inline _local8(context) = (context.v1, context.v2, context.v3, context.v4, context.v5, context.v6, context.v7, context.v8)

@inline _x8(context) = (context.x1, context.x2, context.x3, context.x4, context.x5, context.x6, context.x7, context.x8)
@inline _y8(context) = (context.y1, context.y2, context.y3, context.y4, context.y5, context.y6, context.y7, context.y8)
@inline _z8(context) = (context.z1, context.z2, context.z3, context.z4, context.z5, context.z6, context.z7, context.z8)
@inline _a8(context) = (context.a1, context.a2, context.a3, context.a4, context.a5, context.a6, context.a7, context.a8)
@inline _b8(context) = (context.b1, context.b2, context.b3, context.b4, context.b5, context.b6, context.b7, context.b8)
@inline _c8(context) = (context.c1, context.c2, context.c3, context.c4, context.c5, context.c6, context.c7, context.c8)
@inline _d8(context) = (context.d1, context.d2, context.d3, context.d4, context.d5, context.d6, context.d7, context.d8)
@inline _e8(context) = (context.e1, context.e2, context.e3, context.e4, context.e5, context.e6, context.e7, context.e8)
@inline _f8(context) = (context.f1, context.f2, context.f3, context.f4, context.f5, context.f6, context.f7, context.f8)
@inline _g8(context) = (context.g1, context.g2, context.g3, context.g4, context.g5, context.g6, context.g7, context.g8)
@inline _h8(context) = (context.h1, context.h2, context.h3, context.h4, context.h5, context.h6, context.h7, context.h8)
@inline _i8(context) = (context.i1, context.i2, context.i3, context.i4, context.i5, context.i6, context.i7, context.i8)
@inline _j8(context) = (context.j1, context.j2, context.j3, context.j4, context.j5, context.j6, context.j7, context.j8)
@inline _k8(context) = (context.k1, context.k2, context.k3, context.k4, context.k5, context.k6, context.k7, context.k8)
@inline _l8(context) = (context.l1, context.l2, context.l3, context.l4, context.l5, context.l6, context.l7, context.l8)
@inline _m8(context) = (context.m1, context.m2, context.m3, context.m4, context.m5, context.m6, context.m7, context.m8)
@inline _n8(context) = (context.n1, context.n2, context.n3, context.n4, context.n5, context.n6, context.n7, context.n8)
@inline _o8(context) = (context.o1, context.o2, context.o3, context.o4, context.o5, context.o6, context.o7, context.o8)

@inline function _route8(from, to, prefix::Symbol)
    pairs = ntuple(i -> Symbol(:v, i) => Symbol(prefix, i), 8)
    return Route(from => to, pairs...)
end

@inline function _aggregate8(inputs::NTuple{N, Float64}) where {N}
    s1 = 0.0
    s2 = 0.0
    s3 = 0.0
    s4 = 0.0
    s5 = 0.0
    s6 = 0.0
    s7 = 0.0
    s8 = 0.0

    @inbounds for i in 1:N
        x = inputs[i]
        s1 += sin(x + 0.01 * i)
        s2 += cos(x - 0.02 * i)
        s3 += tanh(x + 0.015 * i)
        s4 += 0.001 * x * x + 0.03 * x
        s5 += exp(-0.05 * abs(x))
        s6 += sqrt(abs(x) + 1) + 0.002 * i
        s7 += 0.5 * sin(0.3 * x) - 0.2 * cos(0.4 * x)
        s8 += 0.25 * x + 0.1 * tanh(0.2 * x)
    end

    return (s1, s2, s3, s4, s5, s6, s7, s8)
end

@inline function _node_update8(state::NTuple{8, Float64}, inputs::NTuple{N, Float64}, phase::Float64 = 0.0) where {N}
    s1, s2, s3, s4, s5, s6, s7, s8 = _aggregate8(inputs)
    v1, v2, v3, v4, v5, v6, v7, v8 = state

    a1 = v1 + 0.13 * s1 - 0.05 * s4 + phase
    a2 = v2 + 0.11 * s2 + 0.04 * s5 - phase
    a3 = v3 + 0.09 * s3 - 0.03 * s6 + 0.5 * phase
    a4 = v4 + 0.08 * s4 + 0.02 * s7
    a5 = v5 + 0.07 * s5 - 0.04 * s8
    a6 = v6 + 0.06 * s6 + 0.03 * s1
    a7 = v7 + 0.05 * s7 - 0.02 * s2
    a8 = v8 + 0.04 * s8 + 0.01 * s3

    @inbounds for _ in 1:12
        a1 = sin(a1) + 0.07 * a2 - 0.03 * a5
        a2 = cos(a2) + 0.06 * a3 + 0.02 * a6
        a3 = tanh(a3) + 0.05 * a4 - 0.02 * a7
        a4 = sqrt(abs(a4) + 1) + 0.04 * a1
        a5 = exp(-0.02 * abs(a5)) + 0.03 * a8
        a6 = tanh(a6 + 0.1 * a2) + 0.02 * a3
        a7 = sin(a7 - 0.05 * a4) + 0.02 * a5
        a8 = cos(a8 + 0.03 * a6) + 0.01 * a7
    end

    return (a1, a2, a3, a4, a5, a6, a7, a8)
end

@inline _root_state(seed, phase) = (; v1 = seed, v2 = 0.7 * seed, v3 = -0.5 * seed, v4 = 0.3 * seed, v5 = -0.2 * seed, v6 = 0.15 * seed, v7 = -0.1 * seed, v8 = 0.05 * seed, phase)
@inline _zero_state() = (; v1 = 0.0, v2 = 0.0, v3 = 0.0, v4 = 0.0, v5 = 0.0, v6 = 0.0, v7 = 0.0, v8 = 0.0)

StatefulAlgorithms.init(::SourceXMerge, context) = _root_state(context.start_x, 0.011)
StatefulAlgorithms.init(::SourceYMerge, context) = _root_state(context.start_y, 0.017)
StatefulAlgorithms.init(::SourceZMerge, context) = _root_state(context.start_z, 0.023)

for T in (StageAMerge, StageBMerge, StageCMerge, StageDMerge, StageEMerge, StageFMerge,
          JoinGMerge, JoinHMerge, JoinIMerge, JoinJMerge, JoinKMerge, JoinLMerge,
          JoinMMerge, JoinNMerge, JoinOMerge)
    @eval StatefulAlgorithms.init(::$T, _context) = _zero_state()
end

StatefulAlgorithms.init(::ReducerMerge, _context) = (; total = 0.0)

function StatefulAlgorithms.step!(::SourceXMerge, context)
    vals = _node_update8(_local8(context), _local8(context), context.phase)
    return (; (_vals8(vals))..., phase = context.phase + 0.011)
end

function StatefulAlgorithms.step!(::SourceYMerge, context)
    vals = _node_update8(_local8(context), _local8(context), context.phase)
    return (; (_vals8(vals))..., phase = context.phase + 0.017)
end

function StatefulAlgorithms.step!(::SourceZMerge, context)
    vals = _node_update8(_local8(context), _local8(context), context.phase)
    return (; (_vals8(vals))..., phase = context.phase + 0.023)
end

function StatefulAlgorithms.step!(::StageAMerge, context)
    return _vals8(_node_update8(_local8(context), _x8(context)))
end

function StatefulAlgorithms.step!(::StageBMerge, context)
    return _vals8(_node_update8(_local8(context), _x8(context)))
end

function StatefulAlgorithms.step!(::StageCMerge, context)
    return _vals8(_node_update8(_local8(context), _y8(context)))
end

function StatefulAlgorithms.step!(::StageDMerge, context)
    return _vals8(_node_update8(_local8(context), _y8(context)))
end

function StatefulAlgorithms.step!(::StageEMerge, context)
    return _vals8(_node_update8(_local8(context), _z8(context)))
end

function StatefulAlgorithms.step!(::StageFMerge, context)
    return _vals8(_node_update8(_local8(context), _z8(context)))
end

function StatefulAlgorithms.step!(::JoinGMerge, context)
    return _vals8(_node_update8(_local8(context), (_a8(context)..., _c8(context)...)))
end

function StatefulAlgorithms.step!(::JoinHMerge, context)
    return _vals8(_node_update8(_local8(context), (_b8(context)..., _d8(context)...)))
end

function StatefulAlgorithms.step!(::JoinIMerge, context)
    return _vals8(_node_update8(_local8(context), (_c8(context)..., _e8(context)...)))
end

function StatefulAlgorithms.step!(::JoinJMerge, context)
    return _vals8(_node_update8(_local8(context), (_d8(context)..., _f8(context)...)))
end

function StatefulAlgorithms.step!(::JoinKMerge, context)
    return _vals8(_node_update8(_local8(context), (_g8(context)..., _h8(context)...)))
end

function StatefulAlgorithms.step!(::JoinLMerge, context)
    return _vals8(_node_update8(_local8(context), (_h8(context)..., _i8(context)...)))
end

function StatefulAlgorithms.step!(::JoinMMerge, context)
    return _vals8(_node_update8(_local8(context), (_i8(context)..., _j8(context)...)))
end

function StatefulAlgorithms.step!(::JoinNMerge, context)
    return _vals8(_node_update8(_local8(context), (_k8(context)..., _l8(context)...)))
end

function StatefulAlgorithms.step!(::JoinOMerge, context)
    return _vals8(_node_update8(_local8(context), (_l8(context)..., _m8(context)...)))
end

function StatefulAlgorithms.step!(::ReducerMerge, context)
    inputs = (_n8(context)..., _o8(context)..., _g8(context)..., _j8(context)...)
    total = context.total
    @inbounds for rep in 1:24
        for x in inputs
            total += sin(x + 0.001 * rep) + 0.02 * x + 0.0005 * x * x
        end
    end
    return (; total)
end

function build_algorithms()
    routes = (
        _route8(SourceXMerge, StageAMerge, :x),
        _route8(SourceXMerge, StageBMerge, :x),
        _route8(SourceYMerge, StageCMerge, :y),
        _route8(SourceYMerge, StageDMerge, :y),
        _route8(SourceZMerge, StageEMerge, :z),
        _route8(SourceZMerge, StageFMerge, :z),

        _route8(StageAMerge, JoinGMerge, :a),
        _route8(StageCMerge, JoinGMerge, :c),
        _route8(StageBMerge, JoinHMerge, :b),
        _route8(StageDMerge, JoinHMerge, :d),
        _route8(StageCMerge, JoinIMerge, :c),
        _route8(StageEMerge, JoinIMerge, :e),
        _route8(StageDMerge, JoinJMerge, :d),
        _route8(StageFMerge, JoinJMerge, :f),

        _route8(JoinGMerge, JoinKMerge, :g),
        _route8(JoinHMerge, JoinKMerge, :h),
        _route8(JoinHMerge, JoinLMerge, :h),
        _route8(JoinIMerge, JoinLMerge, :i),
        _route8(JoinIMerge, JoinMMerge, :i),
        _route8(JoinJMerge, JoinMMerge, :j),

        _route8(JoinKMerge, JoinNMerge, :k),
        _route8(JoinLMerge, JoinNMerge, :l),
        _route8(JoinLMerge, JoinOMerge, :l),
        _route8(JoinMMerge, JoinOMerge, :m),

        _route8(JoinNMerge, ReducerMerge, :n),
        _route8(JoinOMerge, ReducerMerge, :o),
        _route8(JoinGMerge, ReducerMerge, :g),
        _route8(JoinJMerge, ReducerMerge, :j),
    )

    funcs = (
        SourceXMerge, SourceYMerge, SourceZMerge,
        StageAMerge, StageBMerge, StageCMerge, StageDMerge, StageEMerge, StageFMerge,
        JoinGMerge, JoinHMerge, JoinIMerge, JoinJMerge,
        JoinKMerge, JoinLMerge, JoinMMerge,
        JoinNMerge, JoinOMerge,
        ReducerMerge,
    )

    intervals = ntuple(_ -> 1, length(funcs))

    comp = CompositeAlgorithm(funcs..., intervals, routes...)
    threaded = ThreadedCompositeAlgorithm(funcs..., intervals, routes...)

    return comp, threaded
end

function run_once(algo, start_x, start_y, start_z; repeats)
    p = Process(
        algo,
        Input(SourceXMerge, :start_x => start_x),
        Input(SourceYMerge, :start_y => start_y),
        Input(SourceZMerge, :start_z => start_z);
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

function benchmark(algo, start_x, start_y, start_z; repeats, trials, label)
    times = Float64[]
    final_ctx = nothing

    run_once(algo, start_x, start_y, start_z; repeats = 1)
    GC.gc()

    for trial in 1:trials
        elapsed, ctx = run_once(algo, start_x, start_y, start_z; repeats)
        push!(times, elapsed)
        final_ctx = ctx
        GC.gc()
        println(label, " trial ", trial, ": ", round(elapsed; digits = 4), " s")
    end

    return times, final_ctx
end

function assert_match(ref_ctx, other_ctx)
    algos = (
        SourceXMerge, SourceYMerge, SourceZMerge,
        StageAMerge, StageBMerge, StageCMerge, StageDMerge, StageEMerge, StageFMerge,
        JoinGMerge, JoinHMerge, JoinIMerge, JoinJMerge,
        JoinKMerge, JoinLMerge, JoinMMerge,
        JoinNMerge, JoinOMerge,
    )

    for algo in algos
        ref_vals = ref_ctx[algo]
        other_vals = other_ctx[algo]
        for name in MERGE_VALUE_NAMES
            @assert isapprox(getproperty(ref_vals, name), getproperty(other_vals, name); rtol = 0.0, atol = 1e-10)
        end
    end

    ref_sources = ((SourceXMerge, :phase), (SourceYMerge, :phase), (SourceZMerge, :phase))
    for (algo, name) in ref_sources
        @assert isapprox(getproperty(ref_ctx[algo], name), getproperty(other_ctx[algo], name); rtol = 0.0, atol = 1e-12)
    end

    @assert isapprox(ref_ctx[ReducerMerge].total, other_ctx[ReducerMerge].total; rtol = 0.0, atol = 1e-8)
end

function main()
    Random.seed!(4321)

    repeats = 600
    trials = 3
    start_x = randn()
    start_y = randn()
    start_z = randn()

    comp, threaded = build_algorithms()

    println("Repeats: ", repeats)
    println("Trials: ", trials)
    println("Pattern: three roots -> repeated overlapping joins -> deep merge chain -> reducer")
    println("Each non-root step returns 8 updated locals every tick")
    println()

    comp_times, comp_ctx = benchmark(comp, start_x, start_y, start_z; repeats, trials, label = "Composite")
    println()
    threaded_times, threaded_ctx = benchmark(threaded, start_x, start_y, start_z; repeats, trials, label = "Threaded")
    println()
    assert_match(comp_ctx, threaded_ctx)

    comp_best = minimum(comp_times)
    threaded_best = minimum(threaded_times)

    println("Composite best: ", round(comp_best; digits = 4), " s")
    println("Threaded best: ", round(threaded_best; digits = 4), " s")
    println("Threaded / Composite: ", round(threaded_best / comp_best; digits = 3), "x")
    println("Final total: ", round(comp_ctx[ReducerMerge].total; digits = 6))
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
