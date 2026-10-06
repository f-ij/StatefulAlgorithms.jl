# EXPERIMENTAL: loops carry only the persistent fields their steps write.
include("WriteTrace.jl")    # which fields a step writes, found by inference
include("Carry.jl")         # what a loop carries: `create_carried`, `step_context`, `next_carried`, `carried_context`
