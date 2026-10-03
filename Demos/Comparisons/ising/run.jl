# julia --project=Comparison/ising Comparison/ising/run.jl [workload=1|2] [N] [rounds]
using Printf, Random
include(joinpath(@__DIR__, "kernel.jl"))
include(joinpath(@__DIR__, "workload1.jl"))
isfile(joinpath(@__DIR__, "workload2.jl")) && include(joinpath(@__DIR__, "workload2.jl"))

cpu_s() = ccall(:clock, Clong, ()) / 1e6

function compare(variants, N; rounds = 9, only = nothing)
    variants = isnothing(only) ? variants : filter(v -> any(o -> occursin(o, first(v)), only), variants)
    for (_, f) in variants; f(2000); end                     # compile
    res = [f(N) for (_, f) in variants]
    ok = all(==(res[1]), res)
    ok || (@warn "RESULTS DIFFER"; foreach(((v, r),) -> println("  ", first(v), " => ", r), zip(variants, res)))
    wall = [Float64[] for _ in variants]; cpu = [Float64[] for _ in variants]
    for _ in 1:rounds, (k, (_, f)) in enumerate(variants)    # interleaved
        GC.gc(false); w0 = time_ns(); c0 = cpu_s(); f(N)
        push!(wall[k], (time_ns() - w0) / 1e9); push!(cpu[k], cpu_s() - c0)
    end
    best = minimum(wall[1])
    println(ok ? "results identical across variants" : "RESULTS DIFFER")
    for (k, (name, f)) in enumerate(variants)
        w = minimum(wall[k])
        slope = max(0.0, ((@allocated f(N)) - (@allocated f(N ÷ 2))) / (N - N ÷ 2))
        @printf("%-42s %8.2f ns/step  x%.2f  (cpu %.3f s, range %.3f-%.3f s, %.1f B/step)\n",
                name, w / N * 1e9, w / best, minimum(cpu[k]), w, maximum(wall[k]), slope)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    which = parse(Int, get(ARGS, 1, "1"))
    N = parse(Int, get(ARGS, 2, "20000000"))
    rounds = parse(Int, get(ARGS, 3, "9"))
    println("julia ", VERSION, "  ", strip(read(`uptime`, String)))
    println("StatefulAlgorithms at ", pathof(StatefulAlgorithms))
    only = length(ARGS) >= 4 ? split(ARGS[4], ",") : nothing   # e.g. "D1,D2" to run a subset
    compare(which == 1 ? WORKLOAD1 : WORKLOAD2, N; rounds, only)
end
