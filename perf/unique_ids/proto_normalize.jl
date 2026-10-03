# Prototype (user level, no package changes): a type-erased entry that renames Unique's random ids to 1..N in order of
# first appearance, then dynamically calls the normal constructor, so the pipeline only ever sees SimpleId(1..N).
using StatefulAlgorithms, Printf, UUIDs
const SA = StatefulAlgorithms
@StepAlgorithm function Counter(@managed(x = 0.0)); return (; x = x + 1.0); end
@StepAlgorithm function Tally(@managed(n = 0.0)); return (; n = n + 1.0); end

function normalize_ids(@nospecialize(args...))
    seen = Dict{UUID,Int}()
    out = Vector{Any}(undef, length(args))
    for i in eachindex(args)
        a = args[i]
        if a isa SA.IdentifiableAlgo
            T = typeof(a); p = T.parameters
            if p[2] isa SA.SimpleId
                uuid = typeof(p[2]).parameters[1]::UUID          # the id as a plain value: no specialization on the fresh type
                n = get!(seen, uuid, length(seen) + 1)
                a = (SA.IdentifiableAlgo{p[1], SA.SimpleId(n), p[3], p[4], p[5]})(getfield(a, :func))
            end
        end
        out[i] = a
    end
    return out
end
function stable_composite(@nospecialize(args...))
    normalized = normalize_ids(args...)
    return Base.invokelatest(CompositeAlgorithm, normalized...)
end

function with_unique(n)                        # today
    a = Unique(Counter()); b = Unique(Counter())
    la = run(SA.init(resolve(CompositeAlgorithm(a, b, Tally, (1, 1, 1)))); repeats = n)
    SA.getstoredcontext(la)[Tally].n
end
function with_normalizing_entry(n)             # the same, through the type-erased entry
    a = Unique(Counter()); b = Unique(Counter())
    la = run(SA.init(resolve(stable_composite(a, b, Tally, (1, 1, 1)))); repeats = n)
    SA.getstoredcontext(la)[Tally].n
end
t(f) = (t0 = time_ns(); r = f(); ((time_ns() - t0) / 1e6, r))
@printf("%-6s %22s %34s\n", "call", "Unique today, ms", "through the normalizing entry, ms")
for k in 1:5
    mu, ru = t(() -> with_unique(1000)); mn, rn = t(() -> with_normalizing_entry(1000))
    @printf("%-6d %22.1f %34.1f   results equal: %s\n", k, mu, mn, ru == rn)
end
