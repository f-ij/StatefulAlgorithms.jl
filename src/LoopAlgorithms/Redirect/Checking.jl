#=
The check on a plan's `Redirect`s that needs no context: whether they make a cycle. Run once, when the plan is resolved.
=#

"""
    check_redirect_cycles(registry, options)

Run when a plan is resolved. Throws if the plan's `Redirect`s (among `options`) make a cycle (`b.x → a.y → b.x`, or
`b.x → b.x`): a field in a cycle has no value to read.
"""
function check_redirect_cycles(registry::NameSpaceRegistry, options::Tuple)
    redirected = Dict{Tuple{Symbol, Symbol}, Tuple{Symbol, Symbol}}()   # target field => source field
    for redirect in filter_by_type(Redirect, options)
        resolved = resolve_redirect(registry, redirect)
        for (source, target) in zip(source_fieldnames(resolved), getaliases(resolved))
            redirected[(target_match_by(resolved), target)] = (source_match_by(resolved), source)
        end
    end
    for start in keys(redirected)
        chain = [start]
        next = redirected[start]
        while true
            if next in chain
                path = join(("$(ns).$(name)" for (ns, name) in (chain..., next)), " → ")
                error("Redirect makes a cycle: $path. A field in a cycle has no value to read.")
            end
            push!(chain, next)
            haskey(redirected, next) || break
            next = redirected[next]
        end
    end
    return nothing
end
