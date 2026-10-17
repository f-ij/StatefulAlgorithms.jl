const ProcessEntity = Union{AlgoState, StepAlgorithm}

init(::ProcessEntity, context) = (;)
step!(pe::ProcessEntity, context) = error("step! not implemented for $(typeof(pe))")
cleanup(::ProcessEntity, context) = (;)
function _step! end

include("StepReturns.jl")
include("Matching.jl")

include("AlgoStates/AlgoStates.jl")
include("StepAlgorithmMacro.jl")
