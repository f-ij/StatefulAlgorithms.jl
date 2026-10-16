#=
Function calls as plan children. The DSL turns a call statement (`y = f(x; k = 2)`) into a `Callable`; it is internal,
not something to build by hand.
=#

include("Signature.jl")
include("Matching.jl")
include("Step.jl")
include("Showing.jl")
