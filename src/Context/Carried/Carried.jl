# EXPERIMENTAL: loops carry only the persistent fields their steps write.
include("Writes.jl")        # which fields a step writes, from the plan's types (each node's rule sits next to its `_step!`)
include("Carry.jl")         # what a loop carries: `create_carried`, `carried_context`, `next_carried`
