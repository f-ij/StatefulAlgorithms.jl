# Performance regression suite (not part of the tests).
#
#   julia --project=perf perf/run.jl                      compare against perf/baseline.toml
#   julia --project=perf perf/run.jl --update-baseline    store this run as the new baseline
#   julia --project=perf perf/run.jl --strict             exit non-zero on any warning
#   julia --project=perf perf/run.jl --only Routine       run cases whose name contains "Routine"
#
# For every case the package plan and a hand-written loop computing the same
# results are timed alternately in the same process (minimum over rounds), so the
# reported ratio package / hand-written is mostly independent of machine and load.
# Warnings:
#   TARGET   ratio above the case's target
#   ALLOC    allocates more per step than the case allows
#   REGRESS  ratio got worse than the baseline by more than the tolerance
#   WRONG    results differ from the hand-written loop

using TOML, Printf
include(joinpath(@__DIR__, "cases.jl"))

const ROUNDS = 7
const TOLERANCE = 0.15            # allowed ratio increase vs baseline before REGRESS
const BASELINE = joinpath(@__DIR__, "baseline.toml")
const RUNNERS = (:inline, :process)

function run_package(case, runner, N)
    if runner === :inline
        ip = InlineProcess(case.plan(); repeats = N)
        GC.gc(false)
        t = @elapsed run(ip)
        return t, context(ip)
    else
        p = Process(case.plan(); repeats = N)
        GC.gc(false)
        t = @elapsed (run(p); wait(p))
        return t, context(p)
    end
end

function bytes_per_step(case, runner)
    run_package(case, runner, 100)
    measure(N) = runner === :inline ?
        (ip = InlineProcess(case.plan(); repeats = N); @allocated run(ip)) :
        (p = Process(case.plan(); repeats = N); @allocated (run(p); wait(p)))
    small, large = 10_000, 110_000
    measure(small); measure(large)
    return max(0.0, (measure(large) - measure(small)) / (large - small))
end

function measure_case(case, runner)
    N = case.N
    _, ctx = run_package(case, runner, 1_000)             # compile
    case.hand(1_000)
    correct = case.result(run_package(case, runner, N)[2]) == case.hand(N)
    tp = Inf; th = Inf
    for _ in 1:ROUNDS
        tp = min(tp, run_package(case, runner, N)[1])
        GC.gc(false)
        th = min(th, @elapsed case.hand(N))
    end
    steps = N * case.inner
    return (; ns_package = tp / steps * 1e9, ns_hand = th / steps * 1e9,
              ratio = tp / th, bytes = bytes_per_step(case, runner), correct)
end

function main(args)
    update = "--update-baseline" in args
    strict = "--strict" in args
    only = (i = findfirst(==("--only"), args)) === nothing ? nothing : args[i + 1]
    baseline = isfile(BASELINE) ? TOML.parsefile(BASELINE) : Dict{String,Any}()
    results = Dict{String,Any}()
    warnings = String[]

    @printf("%-38s %-8s %9s %9s %7s %7s %9s %8s  %s\n", "case", "runner", "pkg ns", "hand ns", "ratio", "target", "B/step", "baseline", "status")
    for case in CASES, runner in RUNNERS
        only !== nothing && !occursin(only, case.name) && continue
        key = "$(case.name) / $runner"
        r = measure_case(case, runner)
        base = get(get(baseline, "cases", Dict()), key, nothing)
        status = String[]
        r.correct || push!(status, "WRONG")
        r.ratio > case.target && push!(status, "TARGET")
        r.bytes > case.max_bytes && push!(status, "ALLOC")
        base !== nothing && r.ratio > base["ratio"] * (1 + TOLERANCE) && push!(status, "REGRESS")
        @printf("%-38s %-8s %9.3f %9.3f %7.2f %7.2f %9.1f %8s  %s\n", case.name, runner, r.ns_package, r.ns_hand, r.ratio, case.target, r.bytes,
            base === nothing ? "-" : @sprintf("%.2f", base["ratio"]), isempty(status) ? "ok" : join(status, ","))
        isempty(status) || push!(warnings, "$key: $(join(status, ", "))" * (isempty(case.note) ? "" : "  ($(case.note))"))
        results[key] = Dict("ratio" => r.ratio, "ns_package" => r.ns_package, "ns_hand" => r.ns_hand, "bytes_per_step" => r.bytes)
    end

    if update
        commit = try readchomp(`git -C $(@__DIR__) rev-parse --short HEAD`) catch; "unknown" end
        meta = Dict("julia" => string(VERSION), "cpu" => Sys.cpu_info()[1].model, "commit" => commit, "threads" => Threads.nthreads())
        merged = only === nothing ? results : merge(get(baseline, "cases", Dict{String,Any}()), results)
        open(BASELINE, "w") do io
            TOML.print(io, Dict("meta" => meta, "cases" => merged); sorted = true)
        end
        println("\nBaseline written to $(relpath(BASELINE)).")
    end

    if isempty(warnings)
        println("\nNo warnings.")
    else
        println("\nWarnings:")
        foreach(w -> println("  ", w), warnings)
    end
    strict && !isempty(warnings) && exit(1)
end

main(ARGS)
