#=
How a `Routine` extends the hooks of loop algorithms (LoopAlgorithms/Hooks.jl): a reset resets its children. The
routine's own hook, a child's stop check, is in Hooks.jl next to this file.
=#

"""Reset a routine before it runs again: resets each child."""
function reset!(r::Routine)
    reset!.(getalgos(r))
end
