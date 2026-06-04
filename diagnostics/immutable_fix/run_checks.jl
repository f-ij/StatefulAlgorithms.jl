"""
Run correctness checks relevant to the immutable widened-field experiment.

Some checks currently fail by design or due to unresolved behavior changes. This
script keeps running after a failure and prints a compact summary.
"""
module ImmutableFixChecks

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))

"""Run one test file in a fresh Julia process and return whether it passed."""
function run_test_file(path::AbstractString)
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(ROOT) -e $(test_expr(path))`
    println("\n[immutable_fix] checking: ", path)
    return success(cmd)
end

"""Build the Julia expression used to include a test file."""
function test_expr(path::AbstractString)
    escaped = replace(path, "\\" => "\\\\", "\"" => "\\\"")
    return "using Test, StatefulAlgorithms; include(\"$escaped\")"
end

"""Run the focused correctness checks and print the expected status."""
function main()
    checks = (
        "test/CompositeDSLTest.jl",
        "test/RuntimeInputsLifecycleTest.jl",
        "test/ContextInjectorTest.jl",
    )
    results = Dict{String,Bool}()
    for check in checks
        results[check] = run_test_file(check)
    end

    println("\n[immutable_fix] summary")
    for check in checks
        println(rpad(check, 38), results[check] ? "PASS" : "FAIL")
    end
    println("\nExpected current failures:")
    println("- RuntimeInputsLifecycleTest: old second shape-widening error no longer throws.")
    println("- ContextInjectorTest: interactive ref update behavior still needs repair.")
    return all(values(results)) ? nothing : exit(1)
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    ImmutableFixChecks.main()
end

