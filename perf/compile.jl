# Compile-time measurements, one per fresh Julia process (called by run.jl).
#
#   julia --project=perf perf/compile.jl precompile      package precompile time
#   julia --project=perf perf/compile.jl "<case name>"   load + first-run compile of one case
#
# Prints one line: `COMPILE key=seconds key=seconds ...` (process CPU seconds;
# precompile is wall seconds because it runs in a child process).

cpu() = ccall(:clock, Culong, ()) / 1e6        # process CPU seconds (CLOCKS_PER_SEC = 1e6 on macOS/Linux)
macro cputime(ex)
    quote
        local c0 = cpu()
        $(esc(ex))
        cpu() - c0
    end
end

const CASE = ARGS[1]

if CASE == "precompile"
    pkg = Base.PkgId(Base.UUID("3c03ca44-5aad-4ad5-81af-1baae4bc194b"), "StatefulAlgorithms")
    t = @elapsed Base.compilecache(pkg)
    println("COMPILE precompile=", t)
    exit()
end

load = @cputime @eval using StatefulAlgorithms
include(joinpath(@__DIR__, "cases.jl"))

# Plain functions for the DSL case; the DSL wraps them as FuncWrapper children.
dsl_f1(x) = x * 0.999 + 1.0
dsl_f2(x) = x * 0.998 + 2.0
dsl_f3(x) = x * 0.997 + 3.0
dsl_f4(x) = x * 0.996 + 4.0
dsl_plan() = @CompositeAlgorithm begin
    @state seed = 1.0
    a = dsl_f1(seed)
    b = dsl_f2(a)
    c = dsl_f3(b)
    d = dsl_f4(c)
end

"""Plans whose compile time is measured, with a variant for reconfiguration (one interval changed)."""
const COMPILE_CASES = Dict(
    "flat composite, 4 children" => (
        () -> CompositeAlgorithm(Lin{1}, Lin{2}, Lin{3}, Lin{4}, (1, 1, 1, 1)),
        () -> CompositeAlgorithm(Lin{1}, Lin{2}, Lin{3}, Lin{4}, (1, 1, 1, 2))),
    "route from interval-10 producer" => (
        () -> CompositeAlgorithm(Lin{1}, Chain{2}, (10, 1), Route(Lin{1} => Chain{2}, :x => :u)),
        () -> CompositeAlgorithm(Lin{1}, Chain{2}, (5, 1), Route(Lin{1} => Chain{2}, :x => :u))),
    "nested composite" => (
        () -> CompositeAlgorithm(CompositeAlgorithm(Lin{1}, Lin{2}, (1, 3)), Lin{3}, (2, 1)),
        () -> CompositeAlgorithm(CompositeAlgorithm(Lin{1}, Lin{2}, (1, 4)), Lin{3}, (2, 1))),
    "wide composite, 32 children" => (
        () -> CompositeAlgorithm((Lin{k} for k in 1:32)..., ntuple(_ -> 1, 32)),
        () -> CompositeAlgorithm((Lin{k} for k in 1:32)..., (ntuple(_ -> 1, 31)..., 2))),
    "flat Routine (1, 1, 1)" => (
        () -> Routine(Lin{1}, Lin{2}, Lin{3}, (1, 1, 1)),
        () -> Routine(Lin{1}, Lin{2}, Lin{3}, (1, 1, 2))),
    "Routine (100, 5)" => (
        () -> Routine(Lin{1}, Lin{2}, (100, 5)),
        () -> Routine(Lin{1}, Lin{2}, (100, 6))),
    "Routine in Routine" => (
        () -> Routine(Routine(Lin{1}, Lin{2}, (1, 1)), Lin{3}, (1, 1)),
        () -> Routine(Routine(Lin{1}, Lin{2}, (1, 2)), Lin{3}, (1, 1))),
    "Routine in Routine, repeats" => (
        () -> Routine(Routine(Lin{1}, Lin{2}, (10, 5)), Lin{3}, (3, 2)),
        () -> Routine(Routine(Lin{1}, Lin{2}, (10, 6)), Lin{3}, (3, 2))),
    "3-level Routine" => (
        () -> Routine(Routine(Routine(Lin{1}, Lin{2}, (1, 2)), Lin{3}, (2, 1)), Lin{4}, (1, 3)),
        () -> Routine(Routine(Routine(Lin{1}, Lin{2}, (1, 3)), Lin{3}, (2, 1)), Lin{4}, (1, 3))),
    "Routine in composite" => (
        () -> CompositeAlgorithm(Routine(Lin{1}, Lin{2}, (2, 3)), Lin{3}, (2, 1)),
        () -> CompositeAlgorithm(Routine(Lin{1}, Lin{2}, (2, 4)), Lin{3}, (2, 1))),
    "composite in Routine" => (
        () -> Routine(CompositeAlgorithm(Lin{1}, Lin{2}, (1, 2)), Lin{3}, (4, 1)),
        () -> Routine(CompositeAlgorithm(Lin{1}, Lin{2}, (1, 3)), Lin{3}, (4, 1))),
    "DSL, 4 plain-function statements" => (dsl_plan, dsl_plan),   # "reconfigure" = rebuilding the same block
)

plan, variant = COMPILE_CASES[CASE]
first_inline = @cputime run(InlineProcess(plan(); repeats = 10))
first_process = @cputime (p = Process(plan(); repeats = 10); run(p); wait(p))
reconfigure = @cputime run(InlineProcess(variant(); repeats = 10))
println("COMPILE load=", load, " first_inline=", first_inline, " first_process=", first_process, " reconfigure=", reconfigure)
