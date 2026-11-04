include("Hooks.jl")                          # extendable base: read_value, write_value
include("StorageWrappers/StorageWrappers.jl")  # each wrapper: its struct and its methods of the hooks above
include("ReadingWriting.jl")                 # _follow_reads, _follow_writes: follow read_value, write_value
