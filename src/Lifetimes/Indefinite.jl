#=
`Indefinite`: runs until the process is paused or closed. No condition of its own: the default stop check.
=#

"""
Struct to define the lifetime of a process
Is a struct so that dispatch can be used to choose the appropriate loop during compile time
"""
struct Indefinite <: IndefiniteLifetime end
