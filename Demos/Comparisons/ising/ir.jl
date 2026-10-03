using Random, StatefulAlgorithms, InteractiveUtils
include(joinpath(@__DIR__, "kernel.jl"))
@StepAlgorithm function MetroC(@managed(spins = fresh_spins()), @managed(rng = Xoshiro(1)), @managed(m = 0))
    m += flip!(spins, rng, 2.0, 0.0)
    return (; m)
end
ip = InlineProcess(MetroC; repeats = 1000)
run(ip)
ci = only(code_typed(StatefulAlgorithms.run, Tuple{typeof(ip)}; optimize = true))
function summarize(ci)
    code = ci.first.code
    println("statements: ", length(code))
    calls = Dict{String,Int}()
    for st in code
        if st isa Expr && st.head in (:invoke, :call)
            f = if st.head === :invoke
                mi = st.args[1]; mi isa Core.CodeInstance && (mi = mi.def)
                string(mi.def.name, " :: ", mi.specTypes)
            else
                string(st.args[1])
            end
            f = first(f, 150)
            calls[f] = get(calls, f, 0) + 1
        end
    end
    for (k, v) in sort(collect(calls); by = last, rev = true)[1:min(end, 25)]
        println("  ", v, "  ", k)
    end
end
summarize(ci)
