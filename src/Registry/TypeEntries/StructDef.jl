"""
    RegistryTypeEntry{T, E}(algos, multipliers, lookup)

One entry of a registry: the algorithms of entry type `T` (`Lin`), as a tuple `algos` of keyed handles (`Lin_1`,
`Lin_2`, ...) whose types are `E`, how often each runs per root step (`multipliers`), and the runtime lookup table
(`lookup`: each algorithm's lookup key, `dynamic_lookup_key`, => its position), used to find values that are not
`isbits`. The multipliers and the lookup table are only read: the registries of all plans of one type share them
(the generated setup, `registry_code`); adding to a registry copies them (`RegistryBuilder(registry)`).
"""
struct RegistryTypeEntry{T,E}
    algos::E
    multipliers::Vector{Float64}
    dynamic_lookup::Dict{LookupKey,Int}
end

RegistryTypeEntry{T}() where {T} = RegistryTypeEntry{T,Tuple{}}((), Float64[], Dict{LookupKey,Int}())
RegistryTypeEntry{T}(algos::E, multipliers, lookup) where {T,E} = RegistryTypeEntry{T,E}(algos, multipliers, lookup)
