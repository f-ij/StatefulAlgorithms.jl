########################################
############## REGISTRY ################
########################################

"""
Namespace registry keyed by static types rather than a runtime dictionary.

Main responsibilities:
1) Orchestrate names between entries that were previously locally managed or assigned.
2) Auto-name entries that do not carry an assigned scope on entry, so scoping is opt-in
   for the user interface while still always enforced internally.
3) Provide static lookup by using values of `isbits` structs (and, via indirection, also
   non-`isbits` values) as keys that map to a symbol name. This performs a static conversion
   from an arbitrary scoped value—or an unscoped value through auto matching—to a symbol key.
   That key is later used by contexts.
4) Provide static iteration over (non-dynamic) entries in the registry

Each entry is expected to contain only `IdentifiableAlgo` wrappers; no other payloads should be
stored directly in a registry entry. `IdentifiableAlgo` drives the matching system (via entry
matching), and it works together with thin containers so that wrapping layers do not affect
identity: a value and any amount of thin wrapping resolve to the same underlying identity.
Auto-scoped values (currently denoted by a `nothing` id, possibly changing to `:auto`)
can be matched by unrolling to the base struct, enabling the opt-in naming model where
the user supplies a struct and does not need to manage scope explicitly.

The registry also tracks a multiplier per entry; this is later used to infer how often an
algorithm will be called relative to the top level of a composed algorithm.

Structure:
    (# Tuple for type 1 (namedinstance1, namedinstance2, ...), # Tuple for type 2 (...), ...)
"""
struct NameSpaceRegistry{E} <: AbstractRegistry
    entries::E # Tuple of RegistryTypeEntry
end

NameSpaceRegistry() = NameSpaceRegistry(tuple())