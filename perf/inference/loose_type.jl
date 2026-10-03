using StatefulAlgorithms, UUIDs
const SA = StatefulAlgorithms
@StepAlgorithm function Counter(@managed(x = 0.0)); return (; x = x + 1.0); end
@StepAlgorithm function Tally(@managed(n = 0.0)); return (; n = n + 1.0); end
su(f, n) = IdentifiableAlgo(f; id = SA.SimpleId(UUID(UInt128(n))))
a = su(Counter(), 1); b = su(Counter(), 2)
plan = CompositeAlgorithm(a, b, Tally, (1, 1, 1))
T = Base.return_types(resolve, (typeof(plan),))[1]
actual = typeof(resolve(plan))
println("inferred type concrete? ", isconcretetype(T), "   actual runtime type concrete? ", isconcretetype(actual))
println("inferred === actual runtime type? ", T === actual)
# find the first non-concrete piece in the inferred type, walking parameters and (for the struct) field types
function loose(x, path, seen = Set{Any}(), depth = 0)
    depth > 12 && return
    x in seen && return; push!(seen, x)
    if x isa Type
        if !isconcretetype(x) && !(x isa DataType && x.name === Type.body.name) && !(x isa DataType && isempty(x.parameters))
            println("  loose at ", path, ": ", first(string(x), 200))
        end
        if x isa DataType
            for (i, p) in enumerate(x.parameters); loose(p, string(path, "{", i, "}"), seen, depth + 1); end
            isconcretetype(x) && for (i, ft) in enumerate(fieldtypes(x)); loose(ft, string(path, ".", fieldname(x, i)), seen, depth + 1); end
        elseif x isa UnionAll
            println("  UnionAll at ", path, ": ", first(string(x), 200))
        end
    end
end
loose(T, "T")
println("--- fields of the actual runtime type:")
for (i, ft) in enumerate(fieldtypes(actual)); println("  ", fieldname(actual, i), " :: ", isconcretetype(ft) ? "concrete" : "NOT concrete: " * first(string(ft), 120)); end
println("\n--- the free type variables of the inferred type:")
U = T
while U isa UnionAll; println("  free variable: ", U.var.name, "  (bounds ", U.var.lb, " <: _ <: ", U.var.ub, ")"); global U = U.body; end
println("parameters of LoopAlgorithm (", length(U.parameters), "), which are free variables:")
for (i, p) in enumerate(U.parameters); println("  [", i, "] ", p isa TypeVar ? "FREE: $(p.name)" : "known"); end
println("struct definition: ", Base.unwrap_unionall(SA.LoopAlgorithm).name.names, "   type params: ", Base.unwrap_unionall(SA.LoopAlgorithm).parameters)
