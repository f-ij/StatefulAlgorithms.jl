"""
    update_keys(algo, registry) -> keyed algo

`algo` (or the algorithm type `algo`) as `registry` stores it, with the key it has there (`registry[algo]`).
"""
function update_keys(func::F, reg::NameSpaceRegistry) where {F <: ProcessEntity}
    reg[func]
end

function update_keys(::Type{F}, reg::NameSpaceRegistry) where {F <: ProcessEntity}
    reg[F]
end

"""
    update_keys(target_registry, ground_registry, changed_names = Dict()) -> registry

`target_registry` with the key of every algorithm replaced by the key the same algorithm has in `ground_registry`
(algorithms not in `ground_registry` keep theirs). `changed_names` is filled with `old key => new key`.
"""
function update_keys(target_reg::NameSpaceRegistry,  ground_reg::NameSpaceRegistry, changed_names = Dict{Symbol,Symbol}())
    _all_entries = all_algos(target_reg)
    for target_entry in _all_entries
        oldname = getkey(target_entry)
        groundval = static_get_match(ground_reg, target_entry)
        if isnothing(groundval) # TODO: Assume it's supposed to be there?
            continue
        end
        changed_names[oldname] = getkey(groundval)
    end
    target_reg = replacecontextkeyss(target_reg, changed_names)
    return target_reg
end


