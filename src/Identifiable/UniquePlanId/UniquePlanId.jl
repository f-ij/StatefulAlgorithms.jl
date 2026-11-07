#=
`UniquePlanId`: the matcher of a `Unique` handle (StructDef.jl, with why it exists and its three forms), and the
entries that turn every id in a value into another form (ReplaceModes.jl), each one `map_matchers_of_type` (Matching.jl).

Included before the handles (Identifiable/StructDef.jl), which hold it. Four files are included later from
StatefulAlgorithms.jl: UniqueKeyMap.jl (the user's handles found through the registry's `UniqueKeyMap`, after the
registry), NumberByKeymapTyped.jl (the typed numbering of a lifetime by that map, kept apart until it is measured),
HookExtensions.jl (its answers to the matching and registry hooks) and Accessors.jl (getters and setters of the map,
after Context/).
=#
include("StructDef.jl")
include("ReplaceModes.jl")
