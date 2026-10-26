#=
`UniquePlanId`: the matcher of a `Unique` handle (StructDef.jl, with why it exists and its three forms), and the
one rewrite that strips (Strip.jl) and numbers (Number.jl) the ids in any value (Rewrite.jl).

Included before the handles (Identifiable/StructDef.jl), which hold it. Two files are included later from
StatefulAlgorithms.jl: HeldIds.jl (the user's handles in a context handed to the user, after the registry) and
HookExtensions.jl (its answers to the matching and registry hooks).
=#
include("StructDef.jl")
include("Hooks.jl")
include("Rewrite.jl")
include("Strip.jl")
include("Number.jl")
