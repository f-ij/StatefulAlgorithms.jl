# Performance regression suite (not part of the tests).
#
#   julia --project=perf perf/run.jl                      compare against perf/baseline.toml
#   julia --project=perf perf/run.jl --update-baseline    store this run as the new baseline
#   julia --project=perf perf/run.jl --strict             exit non-zero on any warning
#   julia --project=perf perf/run.jl --only Routine       run cases whose name contains "Routine"
#   julia --project=perf perf/run.jl --runtime-only       skip compile times
#   julia --project=perf perf/run.jl --compile-only       only compile times
#
# Compile times (package precompile, `using`, first run under InlineProcess and
# Process, and reconfiguring a plan) are measured in fresh processes by
# perf/compile.jl, minimum over samples. They are absolute, so they warn
# (SLOWER) only when more than 25% and more than 0.1 s worse than the baseline.
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

const COMPILE_TOLERANCE = 0.25     # allowed relative increase in compile time vs baseline ...
const COMPILE_MIN_DELTA = 0.1      # ... and it must also be at least this many seconds worse
const COMPILE_SAMPLES = 3          # fresh processes per compile case (minimum is kept)
const COMPILE_CASE_NAMES = ["flat composite, 4 children", "route from interval-10 producer", "nested composite",
    "wide composite, 32 children", "flat Routine (1, 1, 1)", "Routine (100, 5)", "Routine in Routine",
    "Routine in Routine, repeats", "3-level Routine", "Routine in composite", "composite in Routine",
    "DSL, 4 plain-function statements"]

"""Run perf/compile.jl in fresh processes and keep the minimum of every metric."""
function measure_compile(case_name, samples)
    julia = Base.julia_cmd()
    best = Dict{String,Float64}()
    for _ in 1:samples
        out = read(`$julia --startup-file=no --project=$(@__DIR__) $(joinpath(@__DIR__, "compile.jl")) $case_name`, String)
        line = only(filter(startswith("COMPILE "), split(out, '\n')))
        for kv in split(line)[2:end]
            k, v = split(kv, '=')
            best[k] = min(get(best, k, Inf), parse(Float64, v))
        end
    end
    return best
end

function run_compile(baseline, only, warnings)
    results = Dict{String,Any}()
    base_all = get(baseline, "compile", Dict())
    println("\nCompile times (seconds, minimum over fresh processes; `load` and first runs in CPU s, precompile in wall s)")
    @printf("%-38s %-14s %8s %8s  %s\n", "case", "metric", "seconds", "baseline", "status")
    names = ["package precompile"; COMPILE_CASE_NAMES]
    for name in names
        only !== nothing && !occursin(only, name) && continue
        r = name == "package precompile" ? measure_compile("precompile", 2) : measure_compile(name, COMPILE_SAMPLES)
        base = get(base_all, name, Dict())
        for (metric, t) in sort(collect(r))
            metric == "load" && name != first(COMPILE_CASE_NAMES) && continue   # same `using` in every case; report once
            b = get(base, metric, nothing)
            slower = b !== nothing && t > b * (1 + COMPILE_TOLERANCE) && t - b > COMPILE_MIN_DELTA
            @printf("%-38s %-14s %8.3f %8s  %s\n", name, metric, t, b === nothing ? "-" : @sprintf("%.3f", b), slower ? "SLOWER" : "ok")
            slower && push!(warnings, "$name / $metric: compile $(round(t; digits = 2)) s vs baseline $(round(b; digits = 2)) s")
        end
        results[name] = r
    end
    return results
end

function main(args)
    update = "--update-baseline" in args
    strict = "--strict" in args
    runtime = !("--compile-only" in args)
    compile = !("--runtime-only" in args)
    only = (i = findfirst(==("--only"), args)) === nothing ? nothing : args[i + 1]
    baseline = isfile(BASELINE) ? TOML.parsefile(BASELINE) : Dict{String,Any}()
    results = Dict{String,Any}()
    warnings = String[]

    runtime && @printf("%-38s %-8s %9s %9s %7s %7s %9s %8s  %s\n", "case", "runner", "pkg ns", "hand ns", "ratio", "target", "B/step", "baseline", "status")
    for case in CASES, runner in RUNNERS
        runtime || break
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

    compile_results = compile ? run_compile(baseline, only, warnings) : Dict{String,Any}()

    if update
        commit = try readchomp(`git -C $(@__DIR__) rev-parse --short HEAD`) catch; "unknown" end
        meta = Dict("julia" => string(VERSION), "cpu" => Sys.cpu_info()[1].model, "commit" => commit, "threads" => Threads.nthreads())
        cases = merge(get(baseline, "cases", Dict{String,Any}()), results)
        compiles = merge(get(baseline, "compile", Dict{String,Any}()), compile_results)
        open(BASELINE, "w") do io
            TOML.print(io, Dict("meta" => meta, "cases" => cases, "compile" => compiles); sorted = true)
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
