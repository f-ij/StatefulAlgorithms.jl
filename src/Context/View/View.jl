include("StructDef.jl")
include("Hooks.jl")            # extendable base: read_value, write_value, shown_value
include("StorageWrappers/RedirectedVar.jl")    # each wrapper: its struct and its methods of the hooks above
include("StorageWrappers/Maybe.jl")
include("StorageWrappers/InteractiveVar.jl")
include("ReadingWriting.jl")   # _follow_reads, _follow_writes: follow read_value, write_value
include("ContextView.jl")
include("Locations.jl")
include("Old/ProcessContextView.jl")
