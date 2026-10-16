#=
Function calls as plan children. The DSL turns a call statement (`y = f(x; k = 2)`) into a `Callable`; it is internal,
not something to build by hand. `WithWiring` and `From` wire any plan child, so they are exported.
=#
export WithWiring, From

include("Signature.jl")
include("Matching.jl")
include("Step.jl")
include("Wiring.jl")
include("Showing.jl")
