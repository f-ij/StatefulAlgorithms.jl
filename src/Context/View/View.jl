include("StructDef.jl")
include("Hooks.jl")     # extendable base: read_value, write_value, shown_value
include("Reading.jl")   # _follow_reads: follows read_value
include("Writing.jl")   # _follow_writes: follows write_value
include("ContextView.jl")
include("Locations.jl")
include("Old/ProcessContextView.jl")
