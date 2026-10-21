include("StructDef.jl")
include("Hooks.jl")     # extendable base: read_action, _redirected_varlocation, writeback_value, shown_value
include("Reading.jl")   # read_value: follows read_action
include("ContextView.jl")
include("Locations.jl")
include("Old/ProcessContextView.jl")
