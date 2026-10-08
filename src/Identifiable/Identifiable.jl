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

"""The name an automatic key starts with: `T_i` for an entity of type `T`, unless the type says otherwise."""
autokey_basename(f) = nameoftype(f)

isidentifiable(obj) = false # Trait to signify that an algorithm has an identity

include("VarAlias.jl")
include("AbstractInterface.jl")
include("StructDef.jl")
include("Constructors.jl")
include("IdentifiableAlgos.jl")
include("IdReconstruction.jl")
include("Merging.jl")
include("Init.jl")
