include(joinpath(@__DIR__, "proto_normalize_defs.jl"))
ms(f) = (t0 = time_ns(); r = f(); ((time_ns() - t0) / 1e6, r))
function phases()
    t1, (a, b) = ms(() -> (Unique(Counter()), Unique(Counter())))
    t2, norm = ms(() -> normalize_ids(a, b, Tally, (1, 1, 1)))
    t3, plan = ms(() -> Base.invokelatest(CompositeAlgorithm, norm...))
    t4, res = ms(() -> resolve(plan))
    t5, la = ms(() -> SA.init(res))
    t6, out = ms(() -> run(la; repeats = 1000))
    return (t1, t2, t3, t4, t5, t6)
end
phases(); phases()
@printf("%-26s %9s %9s %9s %9s %9s %9s %9s\n", "", "Unique x2", "normalize", "construct", "resolve", "init", "run", "total")
for k in 1:4
    p = phases(); @printf("normalizing entry, call %d  %9.1f %9.1f %9.1f %9.1f %9.1f %9.1f %9.1f\n", k, p..., sum(p))
end
