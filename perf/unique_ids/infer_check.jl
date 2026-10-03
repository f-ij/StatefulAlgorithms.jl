include(joinpath(@__DIR__, "proto_normalize_defs.jl"))
a = Unique(Counter()); b = Unique(Counter())
norm = normalize_ids(a, b, Tally, (1, 1, 1))                 # the boundary: args with random ids -> sequential ids
plan = Base.invokelatest(CompositeAlgorithm, norm...)          # the core is entered with concrete, normalized types
res = resolve(plan); la = SA.init(res)
short(x) = (s = string(x); length(s) > 90 ? s[1:90] * "..." : s)
println("boundary:  return type inferred for stable_composite(a, b, Tally, (1,1,1)): ",
        short(Base.return_types(stable_composite, (typeof(a), typeof(b), typeof(Tally), Tuple{Int,Int,Int}))[1]))
println("core:      resolve(plan)   ->  ", short(Base.return_types(resolve, (typeof(plan),))[1]))
println("core:      init(resolved)  ->  ", short(Base.return_types(SA.init, (typeof(res),))[1]))
println("core:      concrete (not Any / not abstract)? resolve: ", isconcretetype(Base.return_types(resolve, (typeof(plan),))[1]),
        ", init: ", isconcretetype(Base.return_types(SA.init, (typeof(res),))[1]))
println("the plan's type contains random ids? ", occursin(r"SimpleId\{[0-9a-f]{8}-", string(typeof(plan))), "   sequential ids: ",
        join(unique(m.match for m in eachmatch(r"SimpleId\{\d+\}", string(typeof(plan)))), ", "))

# walk the type parameters recursively: which UUID values (random ids) and which integer ids appear?
function find_ids!(found::Vector{Any}, @nospecialize(x), seen = Base.IdSet{Any}())
    x in seen && return found
    push!(seen, x)
    if x isa UUID; push!(found, x)
    elseif x isa SA.SimpleId; push!(found, typeof(x).parameters[1])
    elseif x isa DataType; for p in x.parameters; find_ids!(found, p, seen); end
    elseif x isa UnionAll; find_ids!(found, x.body, seen)
    elseif x isa Tuple || x isa Core.SimpleVector; for p in x; find_ids!(found, p, seen); end
    end
    return found
end
for (name, T) in (("plan built from the NORMALIZED args", typeof(plan)),
                  ("plan built from the ORIGINAL args  ", typeof(Base.invokelatest(CompositeAlgorithm, a, b, Tally, (1, 1, 1)))))
    ids = find_ids!(Any[], T)
    println(name, " -> ids found in the type: ", join(string.(ids), ", "))
end
