#=
`UniquePlanId`: the matcher of a `Unique` handle (StructDef.jl, with why it exists and its three forms), and the
one replacement of the ids in any value (ReplaceIds.jl) with its modes, strip, number and map (ReplaceModes.jl).

Included before the handles (Identifiable/StructDef.jl), which hold it. Three files are included later from
StatefulAlgorithms.jl: UniqueKeyMap.jl (the user's handles found through the registry's `UniqueKeyMap`, after the
registry), HookExtensions.jl (its answers to the matching and registry hooks) and Accessors.jl (getters and setters of
the map, after Context/).
=#
include("StructDef.jl")
include("Hooks.jl")
include("ReplaceIds.jl")
include("ReplaceModes.jl")
