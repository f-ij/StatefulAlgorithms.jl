# Run every experiment on both backends, check they agree exactly, then count what each one cost.
#
#   julia -t 1 --project=Demos/gray_scott Demos/gray_scott/experiments/compare.jl
#
# Cost = code lines (no blanks or comments) between `#>> Ek` / `#<< Ek` markers, plus single lines
# ending in `#>> Ek`, in SA/experiments.jl and Bespoke/experiments.jl.

using Printf

module SAExp;       include(joinpath(@__DIR__, "SA", "experiments.jl"));      end
module BespokeExp;  include(joinpath(@__DIR__, "Bespoke", "experiments.jl")); end

# ── 1. same results? ────────────────────────────────────────────────────────────────────────
const N, NITER = 64, 3000
a = SAExp.run_experiments(N, NITER)
b = BespokeExp.run_experiments(N, NITER)
println("E1 controller, E2 recorder, E4 probe, composed with the physics ($NITER iterations, n = $N)")
for k in (:V, :feed, :steps, :rec, :rec_head, :probe, :integral)
    @printf("   %-10s identical: %s\n", k, getfield(a, k) == getfield(b, k))
end
sa_curve, be_curve = SAExp.run_sweep(N, 300), BespokeExp.run_sweep(N, 300)
println("E3 sweep (feed ramp up and down, relax at each point)")
@printf("   %-10s identical: %s\n", "curve", sa_curve == be_curve)
println("   coverage vs feed: ", join([@sprintf("%.3f→%.2f", f, c) for (f, c) in sa_curve], "  "))

# ── 2. what did each experiment cost? ───────────────────────────────────────────────────────
function marked_lines(path)
    cost = Dict{String,Int}(); total = 0; label = nothing
    for line in eachline(path)
        t = strip(line)
        iscode = !isempty(t) && !startswith(t, "#")
        total += iscode
        if (m = match(r"^#>> (E\d)", t)) !== nothing
            label = m.captures[1]
        elseif startswith(t, "#<< ")
            label = nothing
        elseif (m = match(r"\S.*#>> (E\d)", line)) !== nothing           # code line ending in a marker
            cost[m.captures[1]] = get(cost, m.captures[1], 0) + 1
        elseif label !== nothing && iscode
            cost[label] = get(cost, label, 0) + 1
        end
    end
    return cost, total
end
sa_cost, sa_total = marked_lines(joinpath(@__DIR__, "SA", "experiments.jl"))
be_cost, be_total = marked_lines(joinpath(@__DIR__, "Bespoke", "experiments.jl"))
println("\ncode lines per experiment")
@printf("   %-14s %6s %9s\n", "", "SA", "bespoke")
names = Dict("E1" => "controller", "E2" => "recorder", "E3" => "sweep", "E4" => "probe")
for k in sort(collect(keys(names)))
    @printf("   %-14s %6d %9d\n", "$k $(names[k])", get(sa_cost, k, 0), get(be_cost, k, 0))
end
sa_exp, be_exp = sum(values(sa_cost)), sum(values(be_cost))
@printf("   %-14s %6d %9d\n", "experiments", sa_exp, be_exp)
@printf("   %-14s %6d %9d   (scaffold = experiments file minus experiments: process wiring / loop skeleton, run helpers)\n",
        "scaffold", sa_total - sa_exp, be_total - be_exp)

# ── 3. speed ────────────────────────────────────────────────────────────────────────────────
function best(f; rounds = 5)
    f()
    t = Inf
    for _ in 1:rounds
        GC.gc(); t0 = time_ns(); f(); t = min(t, (time_ns() - t0) / 1e6)
    end
    return t
end
println("\nspeed, min of 5 (load: ", strip(read(`uptime`, String)), ")")
t_sa = best(() -> SAExp.run_experiments(N, NITER)); t_be = best(() -> BespokeExp.run_experiments(N, NITER))
@printf("   E1+E2+E4 composed   SA %8.1f ms   bespoke %8.1f ms   SA/bespoke %.3f\n", t_sa, t_be, t_sa / t_be)
t_sa = best(() -> SAExp.run_sweep(N, 300)); t_be = best(() -> BespokeExp.run_sweep(N, 300))
@printf("   E3 sweep            SA %8.1f ms   bespoke %8.1f ms   SA/bespoke %.3f\n", t_sa, t_be, t_sa / t_be)
