using StatefulAlgorithms, Printf, UUIDs
const SA = StatefulAlgorithms
@StepAlgorithm function Counter(@managed(x = 0.0)); return (; x = x + 1.0); end
@StepAlgorithm function Reader(x, @managed(seen = 0.0)); return (; seen = x); end

# ---- erased normalizer that also rewrites Routes ----
ordinal(seen::Dict{UUID,Int}, uuid::UUID) = get!(seen, uuid, length(seen) + 1)
function norm_matcher_type(@nospecialize(T), seen)               # SimpleId{uuid} (a type) -> SimpleId{ordinal}
    (T isa DataType && T <: SA.SimpleId && T.parameters[1] isa UUID) ? SA.SimpleId{ordinal(seen, T.parameters[1])} : T
end
function norm_handle_type(@nospecialize(T), seen)                # IdentifiableAlgo{F, SimpleId{uuid}(), ...} (a type)
    if T isa DataType && T <: SA.IdentifiableAlgo && T.parameters[2] isa SA.SimpleId
        p = T.parameters
        return SA.IdentifiableAlgo{p[1], SA.SimpleId(ordinal(seen, typeof(p[2]).parameters[1])), p[3], p[4], p[5]}
    end
    return T
end
function norm_value(@nospecialize(a), seen)
    if a isa SA.IdentifiableAlgo
        T2 = norm_handle_type(typeof(a), seen)
        return T2 === typeof(a) ? a : T2(getfield(a, :func))
    elseif a isa SA.Route
        p = typeof(a).parameters
        newfrom = a.from === nothing ? nothing : norm_value(a.from, seen)
        newto = a.to === nothing ? nothing : norm_value(a.to, seen)
        T2 = SA.Route{norm_matcher_type(p[1], seen), norm_matcher_type(p[2], seen), p[3], p[4], p[5], p[6], typeof(newfrom), typeof(newto)}
        return T2(newfrom, newto)
    end
    return a
end
function normalize_all(@nospecialize(args...))
    seen = Dict{UUID,Int}()
    out = Vector{Any}(undef, length(args))
    for i in eachindex(args); out[i] = norm_value(args[i], seen); end
    return out
end
stable_composite(@nospecialize(args...)) = Base.invokelatest(CompositeAlgorithm, normalize_all(args...)...)

function compile_ms(f)
    Base.cumulative_compile_timing(true); t0 = Base.cumulative_compile_time_ns()[1]
    r = f()
    t1 = Base.cumulative_compile_time_ns()[1]; Base.cumulative_compile_timing(false)
    return (t1 - t0) / 1e6, r
end
wall(f) = (t0 = time_ns(); r = f(); ((time_ns() - t0) / 1e6, r))

function today(n)
    a = Unique(Counter()); b = Unique(Counter())
    la = run(SA.init(resolve(CompositeAlgorithm(a, b, Reader, (1, 1, 1), Route(b => Reader, :x)))); repeats = n)
    SA.getstoredcontext(la)[Reader].seen
end
function normalized(n)
    a = Unique(Counter()); b = Unique(Counter())
    la = run(SA.init(resolve(stable_composite(a, b, Reader, (1, 1, 1), Route(b => Reader, :x)))); repeats = n)
    SA.getstoredcontext(la)[Reader].seen
end
today(10); normalized(10)
@printf("%-6s %26s %30s\n", "call", "today: compile ms / wall ms", "normalizing entry: compile / wall")
for k in 1:4
    (ct, _), (wt, rt) = (compile_ms(() -> today(1000)), wall(() -> today(1000)))
    (cn, _) = compile_ms(() -> normalized(1000)); (wn, rn) = wall(() -> normalized(1000))
    @printf("%-6d %12.1f / %-11.1f %16.1f / %-8.1f results equal: %s\n", k, ct, wt, cn, wn, rt == rn)
end
