#=
How a `Routine` extends the hooks of loop algorithms (LoopAlgorithms/Hooks.jl): a reset resets its children.
=#

"""Reset a routine before it runs again: resets each child."""
function reset!(r::Routine)
    reset!.(getalgos(r))
end
