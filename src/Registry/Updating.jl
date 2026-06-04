"""
Rebuild by applying func to all entries in the registry
"""
function rebuild(func::F, registry::NameSpaceRegistry) where {F}
    type_entries = getentries(registry)
    new_entries = func.(type_entries)
    setfield(registry, :entries, new_entries)
end

"""
Rebuild all entries by applying a func to the ScopedValueEntry
"""
function rebuild_type_entries(func::F, registry::NameSpaceRegistry) where {F}
    rebuild(registry) do entry
        rebuild(func, entry)
    end
end

"""
Scoped Algorithms or thin_wrapped scoped algorithms that need an updated name
    Can be matched with a new registry and rebuilt accordingly
"""
function update_keys(func::F, reg::NameSpaceRegistry) where {F <: ProcessEntity}
    reg[func]
    # if func isa IdentifiableAlgo
    #     @DebugMode println("Updating name for IdentifiableAlgo: $func using registry: $reg")

    #     newval = static_get_match(reg, func)
    #     allentries = all_entries(reg)
    #     if isnothing(newval)
    #         error("Tyring to update name of function $(func) but no match found in registry $reg")
    #     end
    #     return setcontextkey(func, getkey(newval))
    # end
    # # Default: keep non-Identifiable algorithms unchanged.
    # return func
end

function update_keys(::Type{F}, reg::NameSpaceRegistry) where {F <: ProcessEntity}
    reg[F]
end

"""
Changes all the names in target_reg to match those in ground_reg
    Matched by thincontainer contained_type

    Can be supplied with a Dict of changed names to fill
"""
function update_keys(target_reg::NameSpaceRegistry,  ground_reg::NameSpaceRegistry, changed_names = Dict{Symbol,Symbol}())
    # changed_names = Dict{Symbol,Symbol}() # old name => new name
    _all_entries = all_entries(target_reg)
    for target_entry in _all_entries
        oldname = getkey(target_entry)
        groundval = static_get_match(ground_reg, target_entry)
        if isnothing(groundval) # TODO: Assume it's supposed to be there?
            continue
        end
        # if !isnothing(changed_names)
        changed_names[oldname] = getkey(groundval)
        # end
    end
    target_reg = replacecontextkeyss(target_reg, changed_names)
    return target_reg
end


##################################
###### REPLACING ALL NAMES #######
##################################

# """
# Replace 
# """
# function replace_all_keys(reg::NameSpaceRegistry, name::Symbol)
#     func = valentry -> setcontextkey(valentry, name)
#     rebuild_type_entries(func, reg)
# end

# function replace_all_keys(cla::LoopAlgorithm, name::Symbol)
#     newfuncs = replace_all_keys.(getalgos(cla), name)
#     new_registry = replace_all_keys(getregistry(cla), name)
#     cla = setfield(cla, :funcs, newfuncs)
#     cla = setfield(cla, :registry, new_registry)
#     return cla
# end
