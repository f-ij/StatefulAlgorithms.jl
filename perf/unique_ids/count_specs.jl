# reuses the definitions of measure_us.jl (everything before the driver lines), then counts compiled variants and times the phases
src = read("measure_us.jl", String); include_string(Main, src[1:first(findfirst("ap, layout = ARGS", src)) - 1])
using Printf, Statistics
nspec(f) = sum(length(collect(Base.specializations(m))) for m in methods(f))
fresh() = Any[Unique(Counter()), Unique(Counter())]
println("compiled variants of the entry functions after N fresh-uuid calls (route layout):")
@printf("%-26s %8s %8s %8s %8s\n", "entry version", "N = 1", "N = 5", "N = 20", "N = 50")
for ap in ("none", "nospec", "both")
    comp = getfield(Main, Symbol("stable_composite_", ap)); rt = getfield(Main, Symbol("stable_route_", ap)); nv = getfield(Main, Symbol("norm_value_", ap))
    counts = Int[]
    n = 0
    for target in (1, 5, 20, 50)
        while n < target
            a, b = fresh()
            plan = Base.invokelatest(comp, a, b, Reader, (1, 1, 1), Base.invokelatest(rt, b, Reader, :x))
            n += 1
        end
        push!(counts, nspec(comp) + nspec(nv) + nspec(rt))
    end
    @printf("%-26s %8d %8d %8d %8d\n", ap == "none" ? "no marker" : ap == "nospec" ? "@nospecialize" : "@nospecialize + infer", counts...)
end

println("\nphases of ONE call after compilation, microseconds (median of 30 fresh-uuid calls, route layout):")
us(f) = (t0 = time_ns(); r = f(); ((time_ns() - t0) / 1e3, r))
function phases(ap)
    a, b = fresh()
    t1 = us(() -> (Unique(Counter()), Unique(Counter())))[1]
    comp = getfield(Main, Symbol("stable_composite_", ap)); rt = getfield(Main, Symbol("stable_route_", ap))
    t2, plan = us(() -> Base.invokelatest(comp, a, b, Reader, (1, 1, 1), Base.invokelatest(rt, b, Reader, :x)))
    t3, res = us(() -> resolve(plan)); t4, la = us(() -> SA.init(res)); t5, out = us(() -> run(la; repeats = 1000))
    return [t1, t2, t3, t4, t5]
end
for _ in 1:5; phases("both"); end
P = hcat((phases("both") for _ in 1:30)...)
@printf("%-34s %s\n", "phase", "median microseconds")
for (i, name) in enumerate(["create 2 Unique handles", "entry: rename ids + construct plan", "resolve", "init (build the context)", "run, 1000 iterations"])
    @printf("%-34s %.1f\n", name, median(P[i, :]))
end
