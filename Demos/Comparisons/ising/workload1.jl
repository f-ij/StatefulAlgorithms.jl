# Workload 1: Metropolis with an annealed temperature, one flip per step.
# Every variant returns (total magnetisation, sum(spins)) and must agree exactly.
using StatefulAlgorithms, OrdinaryDiffEqFunctionMap, SciMLBase

#### A. hand-written loop, everything local (the ideal) ####
@noinline function w1_hand(N)
    spins = fresh_spins(); rng = Xoshiro(1); m = 0
    for step in 1:N
        m += flip!(spins, rng, anneal_T(step, N), 0.0)
    end
    return (m, sum(spins))
end

#### A2. hand-written loop over state built outside it (as in any real process) ####
# In A the rng never leaves the function, so the compiler can keep its state in registers.
# Here it is created by the caller, like the rng in a process context or a struct.
@noinline function w1_hand_loop(spins, rng, N)
    m = 0
    for step in 1:N
        m += flip!(spins, rng, anneal_T(step, N), 0.0)
    end
    return m
end
function w1_hand_outside(N)
    spins = fresh_spins(); rng = Xoshiro(1)
    m = w1_hand_loop(spins, rng, N)
    return (m, sum(spins))
end

#### B1. struct design: T is a mutable field written by a protocol object ####
mutable struct Sim1{R}
    spins::Matrix{Int8}; rng::R; T::Float64; m::Int
end
struct Anneal1; N::Int; end
@inline anneal!(p::Anneal1, s::Sim1, step) = (s.T = anneal_T(step, p.N); nothing)
@inline metro!(s::Sim1) = (s.m += flip!(s.spins, s.rng, s.T, 0.0); nothing)
@noinline function w1_struct_mutable(N)
    s = Sim1(fresh_spins(), Xoshiro(1), T0, 0); p = Anneal1(N)
    for step in 1:N
        anneal!(p, s, step); metro!(s)
    end
    return (s.m, sum(s.spins))
end

#### B2. struct design, best case: the protocol returns T, the sim is passed it ####
mutable struct Sim2{R}
    spins::Matrix{Int8}; rng::R; m::Int
end
@inline temperature(p::Anneal1, step) = anneal_T(step, p.N)
@inline metro!(s::Sim2, T) = (s.m += flip!(s.spins, s.rng, T, 0.0); nothing)
@noinline function w1_struct_value(N)
    s = Sim2(fresh_spins(), Xoshiro(1), 0); p = Anneal1(N)
    for step in 1:N
        metro!(s, temperature(p, step))
    end
    return (s.m, sum(s.spins))
end

#### C. StatefulAlgorithms: two algorithms, T routed from one to the other ####
@StepAlgorithm function Metro1(T, @managed(spins = fresh_spins()), @managed(rng = Xoshiro(1)), @managed(m = 0))
    m += flip!(spins, rng, T, 0.0)
    return (; m)
end
@StepAlgorithm begin
    @config N::Int = 1
    function Anneal(@managed(step = 1), @managed(T = T0))
        T = anneal_T(step, N)
        step += 1
        return (; step, T)
    end
end
function w1_framework(N)
    a = Anneal(N = N)
    ip = InlineProcess(CompositeAlgorithm(a, Metro1, (1, 1), Route(a => Metro1, :T)); repeats = N)
    run(ip); c = context(ip)
    return (c[Metro1].m, sum(c[Metro1].spins))
end

#### C2. same, with the opt-in `@inline` on the algorithm ####
@StepAlgorithm @inline function Metro1i(T, @managed(spins = fresh_spins()), @managed(rng = Xoshiro(1)), @managed(m = 0))
    m += flip!(spins, rng, T, 0.0)
    return (; m)
end
function w1_framework_inline(N)
    a = Anneal(N = N)
    ip = InlineProcess(CompositeAlgorithm(a, Metro1i, (1, 1), Route(a => Metro1i, :T)); repeats = N)
    run(ip); c = context(ip)
    return (c[Metro1i].m, sum(c[Metro1i].spins))
end

#### D. SciML FunctionMap (discrete problem), best case: no callbacks, no saving ####
mutable struct SciP{R}
    spins::Matrix{Int8}; rng::R; N::Int
end
function f_t!(du, u, p, t)
    du[1] = u[1] + flip!(p.spins, p.rng, anneal_T(t, p.N), 0.0)
    return nothing
end
const SCI_OPTS = (; dt = 1.0, save_everystep = false, save_start = false, dense = false,
                    calck = false, alias_u0 = true)
function w1_sciml_solve(N)
    p = SciP(fresh_spins(), Xoshiro(1), N)
    sol = solve(DiscreteProblem(f_t!, [0], (1.0, Float64(N)), p), FunctionMap(); SCI_OPTS...)
    return (sol.u[end][1], sum(p.spins))
end
function w1_sciml_step(N)
    p = SciP(fresh_spins(), Xoshiro(1), N)
    integ = SciMLBase.init(DiscreteProblem(f_t!, [0], (1.0, Float64(N)), p), FunctionMap(); SCI_OPTS...)
    for _ in 1:N-1; SciMLBase.step!(integ); end
    return (integ.u[1], sum(p.spins))
end

#### D2. SciML, composed like the others: a callback writes the protocol value ####
mutable struct SciPT{R}
    spins::Matrix{Int8}; rng::R; N::Int; T::Float64
end
f_p!(du, u, p, t) = (du[1] = u[1] + flip!(p.spins, p.rng, p.T, 0.0); nothing)
function w1_sciml_callback(N)
    p = SciPT(fresh_spins(), Xoshiro(1), N, anneal_T(1, N))
    cb = DiscreteCallback((u, t, i) -> true, i -> (i.p.T = anneal_T(i.t + 1, i.p.N); nothing);
                          save_positions = (false, false))
    sol = solve(DiscreteProblem(f_p!, [0], (1.0, Float64(N)), p), FunctionMap(); callback = cb, SCI_OPTS...)
    return (sol.u[end][1], sum(p.spins))
end

const WORKLOAD1 = [
    "A  hand-written loop, state local"      => w1_hand,
    "A2 hand-written loop, state from caller" => w1_hand_outside,
    "B1 struct, mutable T field"             => w1_struct_mutable,
    "B2 struct, T passed by value"           => w1_struct_value,
    "C  StatefulAlgorithms plan"             => w1_framework,
    "C2 StatefulAlgorithms plan, @inline"    => w1_framework_inline,
    "D1 SciML FunctionMap solve(), T(t)"     => w1_sciml_solve,
    "D1b SciML FunctionMap init/step!, T(t)" => w1_sciml_step,
    "D2 SciML FunctionMap + callback for T"  => w1_sciml_callback,
]
