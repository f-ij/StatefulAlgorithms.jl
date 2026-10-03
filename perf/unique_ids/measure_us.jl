# julia --project=env_perf measure_us.jl <approach> <layout>
#   approach: none | nospec | both | typed | fixed      (none/nospec/both = the same entry with no marker / @nospecialize / @nospecialize + @nospecializeinfer)
#   layout:   plain | route
# One fresh process per (approach, layout). Times in microseconds.
using StatefulAlgorithms, Printf, UUIDs, Statistics
const SA = StatefulAlgorithms
@StepAlgorithm function Counter(@managed(x = 0.0)); return (; x = x + 1.0); end
@StepAlgorithm function Tally(@managed(n = 0.0)); return (; n = n + 1.0); end
@StepAlgorithm function Reader(x, @managed(seen = 0.0)); return (; seen = x); end
struct RouteSpec; from::Any; to::Any; names::Tuple; end

# The entry: renames the random ids to 1..N, rebuilds Routes, then calls the normal constructor.
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
{INFER}function stable_composite_SUF({NS:args...})
    seen = Dict{UUID,Int}(); out = Vector{Any}(undef, length(args))
    for i in eachindex(args); out[i] = norm_value_SUF(args[i], seen); end
    return Base.invokelatest(CompositeAlgorithm, out...)
end
{INFER}stable_route_SUF({NS:from}, {NS:to}, names::Symbol...) = RouteSpec(from, to, names)
"""
function define_family(suf, ns::Bool, infer::Bool)
    code = replace(TEMPLATE, "SUF" => suf)
    code = replace(code, r"\{NS:([^}]+?)\}" => m -> (v = match(r"\{NS:([^}]+?)\}", m).captures[1]; ns ? "@nospecialize($v)" : v))
    code = replace(code, "{INFER}" => infer ? "Base.@nospecializeinfer " : "")
    Core.eval(Main, Meta.parseall(code))
end
define_family("none", false, false); define_family("nospec", true, false); define_family("both", true, true)

# the type-stable alternative: a generated function that works on the argument types
@generated function normalize_typed(args::Tuple)
    seen = Dict{UUID,Int}(); exprs = Any[]
    for (i, T) in enumerate(args.parameters)
        if T <: SA.IdentifiableAlgo && T.parameters[2] isa SA.SimpleId
            p = T.parameters; n = get!(seen, typeof(p[2]).parameters[1]::UUID, length(seen) + 1)
            push!(exprs, :($(SA.IdentifiableAlgo{p[1], SA.SimpleId(n), p[3], p[4], p[5]})(getfield(args[$i], :func))))
        else
            push!(exprs, :(args[$i]))
        end
    end
    return :(tuple($(exprs...)))
end
typed_composite(args...) = CompositeAlgorithm(normalize_typed(args)...)

stable_unique(f, n) = IdentifiableAlgo(f; id = SA.SimpleId(UUID(UInt128(n))))
make_handles(ap) = ap == "fixed" ? Any[stable_unique(Counter(), 1), stable_unique(Counter(), 2)] : Any[Unique(Counter()), Unique(Counter())]
const H = Ref{Any}(nothing)
fam(ap) = ap in ("none", "nospec", "both") ? ap : nothing
Base.@nospecializeinfer function build(ap, layout, @nospecialize(a), @nospecialize(b))
    f = fam(ap)
    if f !== nothing
        comp = getfield(Main, Symbol("stable_composite_", f)); rt = getfield(Main, Symbol("stable_route_", f))
        return layout == "plain" ? Base.invokelatest(comp, a, b, Tally, (1, 1, 1)) :
                                   Base.invokelatest(comp, a, b, Reader, (1, 1, 1), Base.invokelatest(rt, b, Reader, :x))
    elseif ap == "typed"
        return typed_composite(a, b, Tally, (1, 1, 1))
    else   # fixed
        return layout == "plain" ? CompositeAlgorithm(a, b, Tally, (1, 1, 1)) : CompositeAlgorithm(a, b, Reader, (1, 1, 1), Route(b => Reader, :x))
    end
end
function go(ap, layout)
    hs = H[]; a = hs[1]; b = hs[2]
    la = run(SA.init(resolve(build(ap, layout, a, b))); repeats = 1000)
    return SA.getstoredcontext(la)
end
function measure(f)
    Base.cumulative_compile_timing(true); c0 = Base.cumulative_compile_time_ns()[1]; w0 = time_ns()
    f()
    w1 = time_ns(); c1 = Base.cumulative_compile_time_ns()[1]; Base.cumulative_compile_timing(false)
    return ((c1 - c0) / 1e3, (w1 - w0) / 1e3)           # microseconds
end
ap, layout = ARGS[1], ARGS[2]
H[] = make_handles(ap)
c, w = measure(() -> go(ap, layout)); @printf("%s %s FIRST %.0f %.0f\n", ap, layout, c, w)
same = [measure(() -> go(ap, layout)) for _ in 1:8]
@printf("%s %s SAME %.1f %.1f %.1f %.1f\n", ap, layout, median(first.(same)), median(last.(same)), minimum(last.(same)), maximum(last.(same)))
new = Tuple{Float64,Float64}[]
for _ in 1:10; H[] = make_handles(ap); push!(new, measure(() -> go(ap, layout))); end
@printf("%s %s NEW %.1f %.1f %.1f %.1f\n", ap, layout, median(first.(new)), median(last.(new)), minimum(last.(new)), maximum(last.(new)))
