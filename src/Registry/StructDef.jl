"""
    NameSpaceRegistry{E}(entries)

The registry of a resolved plan: every algorithm and state in the plan, each under its key (`Lin_1`, `Lin_2`, ...),
with how often it runs per root step (its multiplier). `entries` is a tuple with one `RegistryTypeEntry` per entry
type (`Lin`, a state type, ...), states first. The keys are what contexts use as subcontext names.

An algorithm is found by its type and its matcher (`match_by`: its id for a handle, its type or value otherwise),
so `reg[algo]`, `getkey(reg, algo)` and `getmultiplier(reg, algo)` work with the algorithm as the user wrote it as
well as with the keyed handle. Built with a `RegistryBuilder` (Builder.jl); read with the functions in Registries.jl.
"""
struct NameSpaceRegistry{E} <: AbstractRegistry
    entries::E # Tuple of RegistryTypeEntry
end

NameSpaceRegistry() = NameSpaceRegistry(tuple())