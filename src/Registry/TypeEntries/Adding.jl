
##########################
##### ADDING ENTRIES #####
##########################

function add(rte::RegistryTypeEntry{T}, obj, multiplier = 1.; withkey::WK = nothing) where {T, WK}
    if isnothing(obj)
        # return rte, nothing
        error("Trying to add `nothing` to RegistryTypeEntry of type $T")
    end

    fidx = findfirst_match(rte, obj)
    if isnothing(fidx) #add new
        entries = getentries(rte)
        current_length = length(entries)

        identifiable = nothing

        if !isnothing(withkey) # If name is given, use that
            identifiable = IdentifiableAlgo(obj, withkey)
        else
            identifiable = Autokey(obj, current_length + 1)
        end

        push!(getmultipliers(rte), multiplier) # Add the multiplier

        newentries = (entries..., identifiable)
        add_dynamic_link!(identifiable, :entries, current_length + 1, rte)
        return setfield(rte, :entries, newentries)::RegistryTypeEntry{T, typeof(newentries)}, identifiable
    else # Existing instance, bump multiplier and get the named version

        # The named version is decided as follows:
        # Given keys are preffered over autokeys but they need to be consistent
        # If the existing entry has an autokey, and the new one has a key, replace it with the new one
        # If the existing entry has a given key, and the new one has a given key, they need to match
        
        if hasautokey(rte[fidx]) && haskey(obj) # If the existing entry has an autokey, and the new one has a key, replace it with the new one
           rte = replace(rte, fidx, obj) # Replace the entry with the new one, and update dynamic lookup
        end

        if hasgivenkey(rte[fidx]) && hasgivenkey(obj) 
            @assert getkey(rte[fidx]) == getkey(obj) "Trying to add an entry with name $(getkey(obj)) but an entry with the same type already exists with name $(getkey(rte[fidx]))"
        end

        if !isnothing(withkey) # Check name match, cannot add two matching objects with different names
            name = getkey(rte[fidx])
            if name != withkey
                error("Trying to add an entry with name $withkey but an entry with the same type already exists with name $name")
            end
        end

        # Some entries allow for merging if they are added with the same key
        # This is decided by the registry_allowmerge trait
        # This requires the entry to implement a merge function
        if registry_allowmerge(rte[fidx], obj)
            rte = replace(rte, fidx, merge(rte[fidx], obj)) # Merge the entry with the existing one
        end

        return add_multiplier!(rte, fidx, multiplier)::typeof(rte), getentries(rte)[fidx]
    end
end
