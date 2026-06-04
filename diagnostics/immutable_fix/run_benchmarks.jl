"""
Run the benchmark probes relevant to the immutable widened-field experiment.

This wrapper keeps the exact commands in one place so other agents can reproduce
the branch-specific performance checks without searching the diagnostics tree.
"""
module ImmutableFixBenchmarks

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))

"""Run a Julia diagnostics script in a fresh process with extra environment."""
function run_diagnostic(script::AbstractString; env = Dict{String,String}())
    merged_env = copy(ENV)
    for (key, value) in env
        merged_env[key] = value
    end
    cmd = setenv(
        `$(Base.julia_cmd()) --startup-file=no --project=$(ROOT) $(joinpath(ROOT, script))`,
        merged_env,
    )
    println("\n[immutable_fix] running: ", script)
    return run(cmd)
end

"""Run the runtime benchmark set for this branch."""
function main(args = ARGS)
    run_diagnostic(
        "diagnostics/inline_route_heavy_benchmark.jl";
        env = Dict(
            "INLINE_ROUTE_HEAVY_RUNS" => "5",
            "INLINE_ROUTE_HEAVY_STEPS" => "20000",
        ),
    )
    run_diagnostic(
        "diagnostics/inline_scalar_dependency_probe.jl";
        env = Dict(
            "SCALAR_DEPENDENCY_STEPS" => "100000",
            "SCALAR_DEPENDENCY_TRIALS" => "100",
        ),
    )
    return nothing
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    ImmutableFixBenchmarks.main()
end
