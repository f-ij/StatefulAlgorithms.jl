include("StructDef.jl")
include("Hooks.jl")            # extendable base: read_value, write_value, shown_value
include("ReadingWriting.jl")   # _follow_reads, _follow_writes: follow read_value, write_value
include("ContextView.jl")
include("Locations.jl")
include("Old/ProcessContextView.jl")
