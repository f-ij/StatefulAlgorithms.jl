"""
Make a zip of varname_in_subcontext => varname_in_localcontext 
    For all variables in the route
"""
function route_to_alias_zip(route::Route, registry::NameSpaceRegistry)
    source_ref = get_source_ref(route)
    target_ref = get_target_ref(route)

    @assert source_ref ∈ registry "Cannot convert Route: $route to Alias if source-namespace ref: $source_ref is not in the registry"
    @assert target_ref ∈ registry "Cannot convert Route: $route to Alias if target-namespace ref: $target_ref is not in the registry"

    _localnames = getaliases(route)
    _subcontextvarnames = source_fieldnames(route)
    
    # return VarAliases(;zip(_subcontextvarnames, _localnames)...)
    return zip(_subcontextvarnames, _localnames)
end

function routes_to_varaliases(identifiable::IdentifiableAlgo, registry::NameSpaceRegistry, routes...)
    if isempty(routes)
        return identifiable
    end

    total_zip = tuple()
    for route in routes
        target_ref = get_target_ref(route)
        # @show target_ref
        if match(identifiable, target_ref)
            total_zip = (total_zip..., route_to_alias_zip(route, registry)...)
        end
    end
    # @show total_zip
    va = VarAliases(;total_zip...)
    return setvaraliases(identifiable, va)
end