include(joinpath(@__DIR__, "proto_normalize_defs.jl"))

# type-stable normalizer: a generated function that works on the TYPES of its arguments
@generated function normalize_typed(args::Tuple)
    seen = Dict{UUID,Int}(); exprs = Any[]
    for (i, T) in enumerate(args.parameters)
        if T <: SA.IdentifiableAlgo && T.parameters[2] isa SA.SimpleId
            p = T.parameters
            n = get!(seen, typeof(p[2]).parameters[1]::UUID, length(seen) + 1)
            push!(exprs, :($(SA.IdentifiableAlgo{p[1], SA.SimpleId(n), p[3], p[4], p[5]})(getfield(args[$i], :func))))
        else
            push!(exprs, :(args[$i]))
        end
    end
    return :(tuple($(exprs...)))
end
stable_composite_typed(args...) = CompositeAlgorithm(normalize_typed(args)...)

ms(f) = (t0 = time_ns(); r = f(); ((time_ns() - t0) / 1e6, r))
function with_typed(n)
    a = Unique(Counter()); b = Unique(Counter())
    t1, plan = ms(() -> stable_composite_typed(a, b, Tally, (1, 1, 1)))
    la = run(SA.init(resolve(plan)); repeats = n)
    return t1, SA.getstoredcontext(la)[Tally].n
end
function with_erased(n)
    a = Unique(Counter()); b = Unique(Counter())
    t1, plan = ms(() -> stable_composite(a, b, Tally, (1, 1, 1)))
    la = run(SA.init(resolve(plan)); repeats = n)
    return t1, SA.getstoredcontext(la)[Tally].n
end
with_typed(10); with_erased(10)
@printf("%-6s %34s %34s\n", "call", "type-stable (generated), entry ms", "type-erased (@nospecialize), entry ms")
for k in 1:5
    (tt, rt) = with_typed(1000); (te, re) = with_erased(1000)
    @printf("%-6d %34.2f %34.2f   results equal: %s\n", k, tt, te, rt == re)
end
println("is the typed entry inferred? ", Base.return_types(stable_composite_typed, (typeof(Unique(Counter())), typeof(Unique(Counter())), typeof(Tally), Tuple{Int,Int,Int}))[1] !== Any)

# how much time does Julia spend COMPILING in each variant? (compile-time counter, not wall clock)
function compile_ms(f)
    Base.cumulative_compile_timing(true)
    t0 = Base.cumulative_compile_time_ns()[1]
    f()
    t1 = Base.cumulative_compile_time_ns()[1]
    Base.cumulative_compile_timing(false)
    return (t1 - t0) / 1e6
end
function with_today(n)
    a = Unique(Counter()); b = Unique(Counter())
    la = run(SA.init(resolve(CompositeAlgorithm(a, b, Tally, (1, 1, 1)))); repeats = n)
    SA.getstoredcontext(la)[Tally].n
end
with_today(10)
println()
@printf("%-34s %14s\n", "per call, fresh Unique x2", "compile, ms")
for k in 1:3
    @printf("%-34s %14.2f\n", "today (random ids)", compile_ms(() -> with_today(1000)))
    @printf("%-34s %14.2f\n", "type-stable normalizer (generated)", compile_ms(() -> with_typed(1000)))
    @printf("%-34s %14.2f\n", "type-erased normalizer", compile_ms(() -> with_erased(1000)))
end
