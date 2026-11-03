include("Interface.jl")         # what every plan type provides
include("Hooks.jl")             # defaults the plan types and schedule entries extend, in their own files
include("Matching.jl")
include("WithWiring.jl")          # before the plan code, which takes `WithWiring` children
include("Callable/Callable.jl")   # before the plan code, which takes `Callable` children
include("Utils.jl")
include("Interval.jl")
include("GetFirst.jl")
include("PlanOptions.jl")
include("CompositeAlgorithms.jl")
include("Routines/Routines.jl")
include("Recipes.jl")
include("FinalizedAlgorithm/FinalizedAlgorithm.jl")
include("Traits.jl")              # plan-type traits (`iscomposite`, `steps_inline`), before the step generators
include("LoopCursor.jl")
include("Setup.jl")
include("Resolving/Resolving.jl")
include("Init.jl")
include("Keys.jl")
include("Accessors.jl")
include("Locals/Locals.jl")
include("Outputs.jl")
include("Redirect/Materialization.jl")
include("Redirect/Checking.jl")
include("RuntimeInputs.jl")
include("DirectRuns.jl")           # init, partialinit and run on a plan, with no process around it
include("Step.jl")
include("ProcessAlgorithmStep.jl")
include("Fusing/Fusing.jl")
include("Flatten.jl")
include("BaseExt.jl")
include("ParameterReplacement.jl")
include("Showing.jl")





# function match_cla(claT1::Type{<:AbstractLoopAlgorithm}, checkobj)
#     if !(checkobj <: AbstractLoopAlgorithm)
#         return false
#     end
#     return getid(claT1) == getid(checkobj)
# end
