function TypeIdentity(algo)
    type = if algo isa Type
        algo    
    else
        typeof(algo)
    end
    return IdentifiableAlgo(instantiate(algo), id = type)
end