# julia measure.jl <snapshot-label> <process-index>
# Times each phase of bench_block.jl: compile time and wall time in microseconds.
using StatefulAlgorithms
const SA = StatefulAlgorithms
@StepAlgorithm function Counter(@managed(x = 0.0)); return (; x = x + 1.0); end
@StepAlgorithm function Adder(a, b, @managed(sum = 0.0)); return (; sum = a + b); end
@StepAlgorithm function Reader(x, @managed(seen = 0.0)); return (; seen = x); end
@StepAlgorithm function Watch(x, @managed(n = 0.0)); return (; n = n + x); end

const LABEL = ARGS[1]; const PROC = ARGS[2]
src = read(joinpath(@__DIR__, "bench_block.jl"), String)
sections = Dict{String,Expr}()
for part in split(src, "#=")[2:end]
    name, code = split(part, "=#"; limit = 2)
    sections[name] = Meta.parse("begin\n" * code * "\nend")
end
Base.cumulative_compile_timing(true)
function timed(f)
    c0 = Base.cumulative_compile_time_ns()[1]; t0 = time_ns()
    r = f()
    t1 = time_ns(); c1 = Base.cumulative_compile_time_ns()[1]
    return r, (c1 - c0) / 1e3, (t1 - t0) / 1e3
end
out(scenario, rep, phase, c, w) = println("ROW\t$LABEL\t$PROC\t$scenario\t$rep\t$phase\t$(round(c; digits = 1))\t$(round(w; digits = 1))")
function run_block(scenario, rep; new_handles::Bool)
    if new_handles
        _, c, w = timed(() -> Core.eval(Main, sections["HANDLES"])); out(scenario, rep, "1 create Unique handles", c, w)
    end
    for (sec, label) in (("INNER", "nested @Routine"), ("COMP", "@CompositeAlgorithm"))
        ex, c, w = timed(() -> macroexpand(Main, sections[sec]; recursive = true)); out(scenario, rep, "2 expand macro: $label", c, w)
        _, c, w = timed(() -> Core.eval(Main, ex)); out(scenario, rep, "3 construct: $label", c, w)
    end
    _, c, w = timed(() -> Core.eval(Main, sections["RESOLVE"])); out(scenario, rep, "4 resolve", c, w)
end
run_block("cold", 1; new_handles = true)
for rep in 1:5; run_block("warm, same uuids", rep; new_handles = false); end
for rep in 1:5; run_block("same shape, new uuids", rep; new_handles = true); end
# sanity: resolved plan names are deterministic
println("NAMES\t$LABEL\t", join(string.(SA.all_keys(SA.getregistry(resolved))), ","))
