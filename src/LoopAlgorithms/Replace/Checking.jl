#=
Checks on the `ReplacedVar` markers that `Replace` writes into the persistent context. They run once, when the
replacements are applied (`apply_replace_specs`), so they cost nothing per step.
=#

"""
    check_replace_cycles(context)

Throw an error if following the `ReplacedVar` markers in `context` from some field reaches a field a second time
(`b.x → a.y → b.x`, or `b.x → b.x`); return `nothing` otherwise. A read of a field in a cycle would follow the markers
forever. Each chain of markers is followed once from every field, so the cost grows with the number of fields times
the longest chain.
"""
function check_replace_cycles(context::ProcessContext)
    subcontexts = get_subcontexts(context)
    for namespace in keys(subcontexts), field in keys(getdata(getproperty(subcontexts, namespace)))
        stored = _replace_stored_value(subcontexts, namespace, field)
        stored isa ReplacedVar || continue
        chain = [(namespace, field)]
        while stored isa ReplacedVar
            location = getfield(stored, :varlocation)
            next = (get_subcontextname(location), get_originalname(location))
            if next in chain
                path = join(("$(ns).$(name)" for (ns, name) in (chain..., next)), " → ")
                error("Replace makes a cycle: $path. A field in a cycle has no value to read.")
            end
            push!(chain, next)
            stored = _replace_stored_value(subcontexts, next...)
        end
    end
    return nothing
end

"""The value stored in `namespace.field` of the persistent subcontexts `subcontexts`."""
_replace_stored_value(subcontexts, namespace::Symbol, field::Symbol) =
    getproperty(getdata(getproperty(subcontexts, namespace)), field)
