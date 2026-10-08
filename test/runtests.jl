using Test

# The slowest files first, so that with several processes they do not finish last on their own.
const TEST_FILES = [
    "CompositeDSLTest.jl",
    "ProcessManagerTest.jl",
    "CompositeCompositionTest.jl",
    "InlineBenchmarkTest.jl",
    "InlineProcessConstructorTest.jl",
    "LifetimeTest.jl",
    "FibLucProcessTest.jl",
    "CopyManagerTest.jl",
    "RuntimeInputsLifecycleTest.jl",
    "LoopCursorScheduleTest.jl",
    "PackageTest.jl",
    "RouteWalkerTest.jl",
    "ShareContextTest.jl",
    "RoutingWiringTest.jl",
    "MaterializeLoopAlgorithmTest.jl",
    "LoopAlgorithmEditTest.jl",
    "SymbolIndexingTest.jl",
    "InnerTypeFilterTest.jl",
    "InteractiveTest.jl",
    "ContextExchangeTest.jl",
    "ReplacementTest.jl",
    "ProcessAlgorithmMacroTest.jl",
    "ContextAnalyzerTest.jl",
    "InspectionTest.jl",
    "SavingTest.jl",
    "ContextDeltaTest.jl",
]

#=
By default each test file runs in its own Julia process, several at a time (`SA_TEST_JOBS`, default half the CPU
threads), with the same Julia options and test environment as this one. Processes, not threads: the files define
types and methods at top level and start `Process`es with threads of their own, which is not safe to do from several
threads in one process.

`SA_TEST_SERIAL=1` runs every file in this process, one after another, as before; `SA_TEST_FILE=Name.jl` runs one.
=#
const ONE_FILE = get(ENV, "SA_TEST_FILE", "")

if !isempty(ONE_FILE)
    using StatefulAlgorithms
    @testset "$ONE_FILE" begin
        include(ONE_FILE)
    end
elseif get(ENV, "SA_TEST_SERIAL", "") == "1"
    using StatefulAlgorithms
    @testset "StatefulAlgorithms" begin
        for file in TEST_FILES
            include(file)
        end
    end
else
    jobs = parse(Int, get(ENV, "SA_TEST_JOBS", string(max(1, Sys.CPU_THREADS ÷ 2))))
    julia = Base.julia_cmd()
    project = Base.active_project()
    threads = Threads.nthreads()

    # One child process per file: (file, passed, seconds, output)
    results = asyncmap(TEST_FILES; ntasks = jobs) do file
        cmd = addenv(`$julia --project=$project --threads=$threads $(@__FILE__)`, "SA_TEST_FILE" => file)
        output = IOBuffer()
        seconds = @elapsed passed = success(pipeline(ignorestatus(Cmd(cmd; dir = @__DIR__)); stdout = output, stderr = output))
        return (; file, passed, seconds, output = String(take!(output)))
    end

    for r in results
        r.passed && continue
        println("\n===== ", r.file, " failed; its output: =====\n", r.output)
    end
    println("\nTest file (seconds, own process, $jobs at a time):")
    for r in sort(results; by = r -> -r.seconds)
        println(rpad(r.file, 36), r.passed ? "passed  " : "FAILED  ", round(r.seconds; digits = 1))
    end

    @testset "StatefulAlgorithms" begin
        for r in results
            @test r.passed
        end
    end
end
