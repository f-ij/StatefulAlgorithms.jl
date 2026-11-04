#=
`TimedProcess`: a plan run one step per tick of a Julia `Timer`, which the user can pause, resume and close. Between
two ticks it keeps what a paused `Process` keeps (its state context and the run's runtime context, the cursor in its
session), so it shares `Process`'s accessors, run start and paused-run cleanup (`InteractiveProcess`,
Processes/AbstractProcesses.jl). This file includes the rest of this folder: the struct (StructDef.jl), its constructor
(Constructors.jl), the tick (Loop.jl), its status (Status.jl), the user calls (Lifecycle.jl) and showing (Showing.jl).
=#

include("StructDef.jl")
include("Constructors.jl")
include("Loop.jl")
include("Status.jl")
include("Lifecycle.jl")
include("Showing.jl")
