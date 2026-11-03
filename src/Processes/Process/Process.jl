#=
`Process`: a plan run on its own task, which the user can pause, resume and close while it runs. This file includes
the rest of this folder: its session (Session.jl), start and close listeners (Listeners.jl), the struct
(StructDef.jl), its constructors (Constructors.jl), getters and setters (Accessors.jl), run time and locking
(Tools.jl), state context (Context.jl), loop setup (Loop.jl), copying (Copy.jl), precompiling (Precompile.jl),
showing (Showing.jl), the list of live processes (ProcessList.jl), its status and progress (Status.jl) and the user
calls on a running process (Lifecycle.jl). What every process type shares is one folder up (Interface.jl, Hooks.jl,
Construction.jl, Context.jl).
=#

# The struct holds a session and listeners, so their types come first.
include("Session.jl")
include("Listeners.jl")
include("StructDef.jl")
include("Constructors.jl")
include("Accessors.jl")
include("Tools.jl")
include("Context.jl")
include("Loop.jl")
include("Copy.jl")
include("Precompile.jl")
include("Showing.jl")
include("ProcessList.jl")
include("Status.jl")
include("Lifecycle.jl")
