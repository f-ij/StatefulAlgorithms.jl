# Loops carry only the persistent fields their steps write (see Carry.jl for why).
include("Writes.jl")               # `_find_writable_fields`: the overview, and the rule for any other node
include("WriteSets.jl")            # write sets (`Val` of `(subcontext, field)` pairs): build, combine, read off a payload type
include("RuntimeContextTypes.jl")  # the runtime context type before and after a node, from inference
include("AlgorithmWrites.jl")      # rule for an algorithm: the payload its merge writes
include("PlanWrites.jl")           # rule for a composite, routine or threaded composite: the union over its children
include("Carry.jl")                # what a loop carries: `create_carried`, `with_carried`, `next_carried`
