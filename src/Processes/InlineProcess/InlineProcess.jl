#=
`InlineProcess`: a plan run in the caller's task, fully typed, for tight loops. This file includes the rest of this
folder: its session (Session.jl), the struct (StructDef.jl), its constructors (Constructors.jl), getters and setters
(Accessors.jl), loop setup (Loop.jl), the user calls (Lifecycle.jl) and showing (Showing.jl). What every process type
shares is one folder up (Interface.jl, Hooks.jl, Construction.jl, Context.jl).
=#

# The struct holds a session, so its type comes first.
include("Session.jl")
include("StructDef.jl")
include("Constructors.jl")
include("Accessors.jl")
include("Loop.jl")
include("Lifecycle.jl")
include("Showing.jl")
