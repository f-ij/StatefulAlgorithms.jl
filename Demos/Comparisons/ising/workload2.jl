# Workload 2 (modelled on the manuscript experiments): dynamics + protocol + loggers.
#   every step      : protocol sets T (linear anneal) and h (sine pulse); one Metropolis flip;
#                     a logger pushes the running magnetisation to a trace
#   every K steps   : a diagnostics logger pushes mean magnetisation, top-row magnetisation, energy
# Every variant returns the same summary tuple, which must agree exactly.
using StatefulAlgorithms, OrdinaryDiffEqFunctionMap, SciMLBase

const K = 1000
w2_summary(m, spins, trace, mm, top, en) =
    (m, sum(spins), length(trace), sum(trace), sum(mm), sum(top), sum(en))
w2_vectors(N) = (sizehint!(Float32[], N), sizehint!(Float32[], N ÷ K + 1),
                 sizehint!(Float32[], N ÷ K + 1), sizehint!(Float32[], N ÷ K + 1))

#### A. hand-written loop ####
@noinline function w2_hand_loop(spins, rng, trace, mm, top, en, N)
    m = 0
    for t in 1:N
        h = pulse_h(t, N)
        m += flip!(spins, rng, anneal_T(t, N), h)
        push!(trace, Float32(m))
        if t % K == 0
            push!(mm, Float32(mean_mag(spins))); push!(top, Float32(top_row_mag(spins)))
            push!(en, Float32(energy(spins, h)))
        end
    end
    return m
end
function w2_hand(N)
    spins = fresh_spins(); rng = Xoshiro(1); trace, mm, top, en = w2_vectors(N)
    m = w2_hand_loop(spins, rng, trace, mm, top, en, N)
    return w2_summary(m, spins, trace, mm, top, en)
end

#### B. struct design, best case: components are structs, values passed explicitly, all @inline ####
struct Protocol2; N::Int; end
@inline protocol(p::Protocol2, t) = (anneal_T(t, p.N), pulse_h(t, p.N))
mutable struct Dynamics2{R}; spins::Matrix{Int8}; rng::R; m::Int; end
@inline metro!(d::Dynamics2, T, h) = (d.m += flip!(d.spins, d.rng, T, h); nothing)
struct TraceLogger2; trace::Vector{Float32}; end
@inline log!(l::TraceLogger2, m) = (push!(l.trace, Float32(m)); nothing)
struct DiagLogger2; mm::Vector{Float32}; top::Vector{Float32}; en::Vector{Float32}; end
@inline function log!(l::DiagLogger2, spins, h)
    push!(l.mm, Float32(mean_mag(spins))); push!(l.top, Float32(top_row_mag(spins)))
    push!(l.en, Float32(energy(spins, h))); nothing
end
@noinline function w2_struct_loop(p, d, tl, dl, N)
    for t in 1:N
        T, h = protocol(p, t)
        metro!(d, T, h)
        log!(tl, d.m)
        t % K == 0 && log!(dl, d.spins, h)
    end
end
function w2_struct(N)
    trace, mm, top, en = w2_vectors(N)
    d = Dynamics2(fresh_spins(), Xoshiro(1), 0)
    w2_struct_loop(Protocol2(N), d, TraceLogger2(trace), DiagLogger2(mm, top, en), N)
    return w2_summary(d.m, d.spins, trace, mm, top, en)
end

#### C. StatefulAlgorithms: five composable pieces, wired by Route, loggers on intervals ####
@StepAlgorithm begin
    @config N::Int = 1
    function Protocol(@managed(step = 1), @managed(T = T0), @managed(h = 0.0))
        T = anneal_T(step, N); h = pulse_h(step, N)
        step += 1
        return (; step, T, h)
    end
end
@StepAlgorithm function Dynamics(T, h, @managed(spins = fresh_spins()), @managed(rng = Xoshiro(1)), @managed(m = 0))
    m += flip!(spins, rng, T, h)
    return (; m)
end
@StepAlgorithm begin
    @config N::Int = 1
    function TraceLogger(m, @managed(trace = sizehint!(Float32[], N)))
        push!(trace, Float32(m))
        return (;)
    end
end
@StepAlgorithm begin
    @config N::Int = 1
    function DiagLogger(spins, h, @managed(mm = sizehint!(Float32[], N ÷ K + 1)),
                        @managed(top = sizehint!(Float32[], N ÷ K + 1)), @managed(en = sizehint!(Float32[], N ÷ K + 1)))
        push!(mm, Float32(mean_mag(spins))); push!(top, Float32(top_row_mag(spins)))
        push!(en, Float32(energy(spins, h)))
        return (;)
    end
end
@StepAlgorithm @inline function DynamicsI(T, h, @managed(spins = fresh_spins()), @managed(rng = Xoshiro(1)), @managed(m = 0))
    m += flip!(spins, rng, T, h)
    return (; m)
end
function w2_framework_with(Dyn)
    return function (N)
        pr = Protocol(N = N); tl = TraceLogger(N = N); dl = DiagLogger(N = N)
        plan = CompositeAlgorithm(pr, Dyn, tl, dl, (1, 1, 1, K),
            Route(pr => Dyn, :T), Route(pr => Dyn, :h),
            Route(Dyn => tl, :m),
            Route(Dyn => dl, :spins), Route(pr => dl, :h))
        ip = InlineProcess(plan; repeats = N); run(ip); c = context(ip)
        return w2_summary(c[Dyn].m, c[Dyn].spins, c[tl].trace, c[dl].mm, c[dl].top, c[dl].en)
    end
end
const w2_framework = w2_framework_with(Dynamics)
const w2_framework_inline = w2_framework_with(DynamicsI)

#### D. SciML FunctionMap with callbacks for the protocol and both loggers ####
mutable struct SciP2{R}
    spins::Matrix{Int8}; rng::R; N::Int; n::Int; T::Float64; h::Float64
    trace::Vector{Float32}; mm::Vector{Float32}; top::Vector{Float32}; en::Vector{Float32}
end
w2_f!(du, u, p, t) = (du[1] = u[1] + flip!(p.spins, p.rng, p.T, p.h); nothing)
# callbacks run after each step n: trace, diagnostics (at n % K == 0), then the protocol for step n+1
w2_cb_trace(i) = (push!(i.p.trace, Float32(i.u[1])); nothing)
function w2_cb_diag(i)
    p = i.p
    if p.n % K == 0
        push!(p.mm, Float32(mean_mag(p.spins))); push!(p.top, Float32(top_row_mag(p.spins)))
        push!(p.en, Float32(energy(p.spins, p.h)))
    end
    return nothing
end
function w2_cb_proto(i)
    p = i.p; p.n += 1; p.T = anneal_T(p.n, p.N); p.h = pulse_h(p.n, p.N); nothing
end
function w2_sciml(N)
    trace, mm, top, en = w2_vectors(N)
    p = SciP2(fresh_spins(), Xoshiro(1), N, 1, anneal_T(1, N), pulse_h(1, N), trace, mm, top, en)
    nosave = (false, false)
    cbs = CallbackSet(DiscreteCallback((u, t, i) -> true, w2_cb_trace; save_positions = nosave),
                      DiscreteCallback((u, t, i) -> true, w2_cb_diag; save_positions = nosave),
                      DiscreteCallback((u, t, i) -> true, w2_cb_proto; save_positions = nosave))
    sol = solve(DiscreteProblem(w2_f!, [0], (1.0, Float64(N)), p), FunctionMap(); callback = cbs, SCI_OPTS...)
    # The solver does not run callbacks at the end of tspan, so apply the last step's logging
    # by hand (one call; the other N-1 steps all went through the callbacks).
    if length(trace) == N - 1
        p.n = N
        push!(trace, Float32(sol.u[end][1])); w2_cb_diag(( p = p,))
    end
    return w2_summary(sol.u[end][1], p.spins, trace, mm, top, en)
end

const WORKLOAD2 = [
    "A  hand-written loop"                    => w2_hand,
    "B  structs (all @inline, by value)"      => w2_struct,
    "C  StatefulAlgorithms composite"         => w2_framework,
    "C2 StatefulAlgorithms composite, @inline" => w2_framework_inline,
    "D  SciML FunctionMap + 3 callbacks"      => w2_sciml,
]
