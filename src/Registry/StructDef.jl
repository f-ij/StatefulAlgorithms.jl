"""
    NameSpaceRegistry{E}(entries)
    NameSpaceRegistry{E, M}(entries, keymap)

The registry of a resolved plan: every algorithm and state in the plan, each under its key (`Lin_1`, `Lin_2`, ...),
with how often it runs per root step (its multiplier). `entries` is a tuple with one `RegistryTypeEntry` per entry
type (`Lin`, a state type, ...), states first. The keys are what contexts use as subcontext names.

An algorithm is found by its type and its matcher (`match_by`: its id for a handle, its type or value otherwise),
so `reg[algo]`, `getkey(reg, algo)` and `getmultiplier(reg, algo)` work with the algorithm as the user wrote it as
well as with the keyed handle. Built with a `RegistryBuilder` (Builder.jl); read with the functions in Registries.jl.

`keymap` is the plan's `UniqueKeyMap` (the number each `Unique` handle got, `k => uuid`, as type data), put in by
`resolve` (`with_keymap`), so a handle the user holds is found from types (`numbered_handle`). Every registry the user
gets has it; the registry that `init` and the loop compile for has `nothing` there (`strip_keymap`): no uuid in its
type.
"""
struct NameSpaceRegistry{E, M} <: AbstractRegistry
    entries::E # Tuple of RegistryTypeEntry
    keymap::M  # The plan's `UniqueKeyMap`, or `nothing` (no `Unique` handles, or stripped for `init` and the loop)
end
NameSpaceRegistry{E}(entries) where {E} = NameSpaceRegistry{E, Nothing}(entries, nothing)
NameSpaceRegistry(entries::E) where {E} = NameSpaceRegistry{E}(entries)

NameSpaceRegistry() = NameSpaceRegistry(tuple())