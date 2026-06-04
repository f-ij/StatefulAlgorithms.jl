"""
ProcessAlgorithm package with explicitly scoped child algorithms.

`Package` is registered as one root process algorithm. Its children are
`SubPackage` wrappers that carry package-local aliases. They deliberately do
not carry their own root identity; package child views and multipliers are
derived from the containing package view and package-local registry.

`funcs` contains only stepped children. `states` are initialized before those
children and seed the shared package subcontext. `registry` is package-local:
it aggregates matching child execution points so init-time tools such as
`processsizehint!` can ask how often a child algorithm will step without making
children root registry entries. `Intervals` and `CustomName` are type
parameters so schedule and registry-generated names stay compile-time visible.
"""
struct Package{Funcs, States, Intervals, CustomName, Registry} <: ProcessAlgorithm
    funcs::Funcs
    states::States
    inc::Base.RefValue{Int}
    registry::Registry
end
