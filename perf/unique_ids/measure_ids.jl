# julia --project=env_perf measure_ids.jl <approach> <layout>
#   approach: today | erased | erased_route | typed | fixed        layout: plain | route
# One fresh process per (approach, layout), so the first run is a true cold compile.
using StatefulAlgorithms, Printf, UUIDs
const SA = StatefulAlgorithms
@StepAlgorithm function Counter(@managed(x = 0.0)); return (; x = x + 1.0); end
@StepAlgorithm function Tally(@managed(n = 0.0)); return (; n = n + 1.0); end
@StepAlgorithm function Reader(x, @managed(seen = 0.0)); return (; seen = x); end

#### erased normalizer: renames random ids to 1..N in order of first appearance ####
struct RouteSpec; from::Any; to::Any; names::Tuple; end                      # an untyped description of a Route
stable_route(@nospecialize(from), @nospecialize(to), names::Symbol...) = RouteSpec(from, to, names)
ordinal(seen::Dict{UUID,Int}, uuid::UUID) = get!(seen, uuid, length(seen) + 1)
Base.@nospecializeinfer function norm_matcher_type(@nospecialize(T), seen)
    (T isa DataType && T <: SA.SimpleId && T.parameters[1] isa UUID) ? SA.SimpleId{ordinal(seen, T.parameters[1])} : T
end
Base.@nospecializeinfer function norm_handle_type(@nospecialize(T), seen)
    if T isa DataType && T <: SA.IdentifiableAlgo && T.parameters[2] isa SA.SimpleId
        p = T.parameters
        return SA.IdentifiableAlgo{p[1], SA.SimpleId(ordinal(seen, typeof(p[2]).parameters[1])), p[3], p[4], p[5]}
    end
    return T
end
Base.@nospecializeinfer function norm_value(@nospecialize(a), seen)
    if a isa SA.IdentifiableAlgo
        T2 = norm_handle_type(typeof(a), seen)
        return T2 === typeof(a) ? a : T2(getfield(a, :func))
    elseif a isa RouteSpec
        return Base.invokelatest(SA.Route, norm_value(a.from, seen) => norm_value(a.to, seen), a.names...)
    elseif a isa SA.Route
        p = typeof(a).parameters
        nf = a.from === nothing ? nothing : norm_value(a.from, seen); nt = a.to === nothing ? nothing : norm_value(a.to, seen)
        return SA.Route{norm_matcher_type(p[1], seen), norm_matcher_type(p[2], seen), p[3], p[4], p[5], p[6], typeof(nf), typeof(nt)}(nf, nt)
    end
    return a
end
Base.@nospecializeinfer function stable_composite(@nospecialize(args...))
    seen = Dict{UUID,Int}(); out = Vector{Any}(undef, length(args))
    for i in eachindex(args); out[i] = norm_value(args[i], seen); end
    return Base.invokelatest(CompositeAlgorithm, out...)
end

#### type-stable normalizer (plain layout only) ####
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
function make_handles(approach)
    approach == "fixed" ? Any[stable_unique(Counter(), 1), stable_unique(Counter(), 2)] : Any[Unique(Counter()), Unique(Counter())]   # a Vector{Any}: no fresh tuple type
end
Base.@nospecializeinfer function build(approach, layout, @nospecialize(a), @nospecialize(b))
    if layout == "plain"
        approach == "erased" || approach == "erased_route" ? stable_composite(a, b, Tally, (1, 1, 1)) :
        approach == "typed" ? typed_composite(a, b, Tally, (1, 1, 1)) :
        CompositeAlgorithm(a, b, Tally, (1, 1, 1))
    else
        approach == "erased" ? stable_composite(a, b, Reader, (1, 1, 1), Route(b => Reader, :x)) :
        approach == "erased_route" ? stable_composite(a, b, Reader, (1, 1, 1), stable_route(b, Reader, :x)) :
        CompositeAlgorithm(a, b, Reader, (1, 1, 1), Route(b => Reader, :x))
    end
end
const H = Ref{Any}(nothing)                       # handles live in an untyped slot, like locals typed Any in user code
function go(approach, layout)
    hs = H[]; a = hs[1]; b = hs[2]
    la = run(SA.init(resolve(build(approach, layout, a, b))); repeats = 1000)
    return SA.getstoredcontext(la)
end
function measure(f)
    Base.cumulative_compile_timing(true); c0 = Base.cumulative_compile_time_ns()[1]; w0 = time_ns()
    f()
    w1 = time_ns(); c1 = Base.cumulative_compile_time_ns()[1]; Base.cumulative_compile_timing(false)
    return ((c1 - c0) / 1e6, (w1 - w0) / 1e6)
end

approach, layout = ARGS[1], ARGS[2]
H[] = make_handles(approach)
function report(step, (c, w)); @printf("%s %s %-26s compile %9.1f ms   wall %9.1f ms\n", approach, layout, step, c, w); end
report("first run (cold)", measure(() -> go(approach, layout)))
for k in 1:3; report("same handles again #$k", measure(() -> go(approach, layout))); end
for k in 1:4; H[] = make_handles(approach); report("new uuids, same layout #$k", measure(() -> go(approach, layout))); end
