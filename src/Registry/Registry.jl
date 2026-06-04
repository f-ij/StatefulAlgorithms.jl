export getregistry, add, add, find_typeidx, registry_allowmerge
## BUILDS ON THINCONTAINERS
include("Utils.jl")
include("PreferStrongKeyDict.jl")
include("Traits.jl")
include("Findability.jl")

include("StructDef.jl")
include("ScopedValueEntry.jl")
include("TypeEntries/TypeEntries.jl")
include("Registries.jl")
include("SimpleRegistry.jl")
include("Updating.jl")
include("Keys.jl")
# include("Init.jl")
