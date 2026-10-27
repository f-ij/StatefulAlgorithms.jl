#=
`UniquePlanId`: the matcher of a `Unique` handle (StructDef.jl, with why it exists and its three forms), and the
one rewrite of the ids in any value (Rewrite.jl) with its modes, strip, number and drop (RewriteModes.jl).

Included before the handles (Identifiable/StructDef.jl), which hold it. Two files are included later from
StatefulAlgorithms.jl: UniqueKeyMap.jl (the user's handles found through the registry's `UniqueKeyMap`, after the registry) and
HookExtensions.jl (its answers to the matching and registry hooks).
=#
include("StructDef.jl")
include("Hooks.jl")
include("Rewrite.jl")
include("RewriteModes.jl")
