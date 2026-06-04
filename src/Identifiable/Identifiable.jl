#################################
######## RELEVANT TRAITS ########
#################################
function nameoftype(f)
    if f isa Type
        return nameof(f)
    else
        return nameof(typeof(f))
    end
end

isidentifiable(obj) = false # Trait to signify that an algorithm has an identity

include("VarAlias.jl")
include("AbstractInterface.jl")
include("StructDef.jl")
include("Constructors.jl")
include("IdentifiableAlgos.jl")
include("Merging.jl")
include("Init.jl")
