# julia --project=env_perf measure_phases.jl <approach> <layout>
#   approach: today | none | nospec | fixed       layout: plain | route
# Phases (each timed separately): entry (rename ids) | construct the plan | resolve | init | run with ONE iteration.
# Output: microseconds of compile time and of wall time per phase, for the cold call, calls with the same handles, and calls with new handles.
using StatefulAlgorithms, Printf, UUIDs, Statistics
const SA = StatefulAlgorithms
@StepAlgorithm function Counter(@managed(x = 0.0)); return (; x = x + 1.0); end
@StepAlgorithm function Tally(@managed(n = 0.0)); return (; n = n + 1.0); end
@StepAlgorithm function Reader(x, @managed(seen = 0.0)); return (; seen = x); end
struct RouteSpec; from::Any; to::Any; names::Tuple; end

const TEMPLATE = raw"""
{INFER}function norm_matcher_type_SUF({NS:T}, seen)
    (T isa DataType && T <: SA.SimpleId && T.parameters[1] isa UUID) ? SA.SimpleId{get!(seen, T.parameters[1], length(seen) + 1)} : T
end
{INFER}function norm_handle_type_SUF({NS:T}, seen)
    if T isa DataType && T <: SA.IdentifiableAlgo && T.parameters[2] isa SA.SimpleId
        p = T.parameters
        return SA.IdentifiableAlgo{p[1], SA.SimpleId(get!(seen, typeof(p[2]).parameters[1], length(seen) + 1)), p[3], p[4], p[5]}
    end
    return T
end
{INFER}function norm_value_SUF({NS:a}, seen)
    if a isa SA.IdentifiableAlgo
        T2 = norm_handle_type_SUF(typeof(a), seen)
        return T2 === typeof(a) ? a : T2(getfield(a, :func))
    elseif a isa RouteSpec
        return Base.invokelatest(SA.Route, norm_value_SUF(a.from, seen) => norm_value_SUF(a.to, seen), a.names...)
    end
    return a
end
{INFER}function normalize_all_SUF({NS:args...})
    seen = Dict{UUID,Int}(); out = Vector{Any}(undef, length(args))
    for i in eachindex(args); out[i] = norm_value_SUF(args[i], seen); end
    return out
end
{INFER}stable_route_SUF({NS:from}, {NS:to}, names::Symbol...) = RouteSpec(from, to, names)
"""
function define_family(suf, ns::Bool, infer::Bool)
    code = replace(TEMPLATE, "SUF" => suf)
    code = replace(code, r"\{NS:([^}]+?)\}" => m -> (v = match(r"\{NS:([^}]+?)\}", m).captures[1]; ns ? "@nospecialize($v)" : v))
    code = replace(code, "{INFER}" => infer ? "Base.@nospecializeinfer " : "")
    Core.eval(Main, Meta.parseall(code))
end
define_family("none", false, false); define_family("nospec", true, false)

stable_unique(f, n) = IdentifiableAlgo(f; id = SA.SimpleId(UUID(UInt128(n))))
make_handles(ap) = ap == "fixed" ? Any[stable_unique(Counter(), 1), stable_unique(Counter(), 2)] : Any[Unique(Counter()), Unique(Counter())]
const H = Ref{Any}(nothing)

struct Phase; c::Float64; w::Float64; result::Any; end          # compile and wall microseconds
function ph(f)
    c0 = Base.cumulative_compile_time_ns()[1]; w0 = time_ns()
    r = f()
    w1 = time_ns(); c1 = Base.cumulative_compile_time_ns()[1]
    return Phase((c1 - c0) / 1e3, (w1 - w0) / 1e3, r)
end
const NAMES = ("entry", "construct", "resolve", "init", "run(1 iteration)")
function phases(ap, layout)
    hs = H[]; a = hs[1]; b = hs[2]
    if ap == "none" || ap == "nospec"
        norm = getfield(Main, Symbol("normalize_all_", ap)); rt = getfield(Main, Symbol("stable_route_", ap))
        p1 = ph(() -> layout == "plain" ? Base.invokelatest(norm, a, b, Tally, (1, 1, 1)) :
                                          Base.invokelatest(norm, a, b, Reader, (1, 1, 1), Base.invokelatest(rt, b, Reader, :x)))
        args2 = p1.result
        p2 = ph(() -> Base.invokelatest(CompositeAlgorithm, args2...))
    else
        p1 = Phase(0.0, 0.0, nothing)
        p2 = ph(() -> layout == "plain" ? CompositeAlgorithm(a, b, Tally, (1, 1, 1)) : CompositeAlgorithm(a, b, Reader, (1, 1, 1), Route(b => Reader, :x)))
    end
    plan = p2.result
    p3 = ph(() -> resolve(plan)); res = p3.result
    p4 = ph(() -> SA.init(res)); la = p4.result
    p5 = ph(() -> run(la; repeats = 1))
    return [p1, p2, p3, p4, p5]
end

Base.cumulative_compile_timing(true)
ap, layout = ARGS[1], ARGS[2]
H[] = make_handles(ap)
function emit(step, P); for (i, p) in enumerate(P); @printf("%s %s %s %s %.1f %.1f\n", ap, layout, step, replace(NAMES[i], " " => "_"), p.c, p.w); end; end
emit("FIRST", phases(ap, layout)); get(ENV, "COLD_ONLY", "") == "1" && exit()
for k in 1:3; emit("SAME$k", phases(ap, layout)); end
for k in 1:8; H[] = make_handles(ap); emit("NEW$k", phases(ap, layout)); end
