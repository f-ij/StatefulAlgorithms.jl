#=
Context bundles: everything a step (or init) can read and write, packed into one value.

During a loop there are two contexts. The persistent context holds the state of every algorithm and lives for the whole
run. The runtime context holds values that only exist while the loop runs: inputs, declared locals and returns. A
bundle carries both, plus whatever else the phase needs. Views are made from a bundle. Bundles are internal: users only
ever see `ProcessContext`s.

| Bundle        | Used by          | Holds                                                                   |
|:--------------|:-----------------|:------------------------------------------------------------------------|
| `LoopContext` | the loop's steps | persistent context, runtime context, the plan node it is in (type only) |
| `InitContext` | init             | persistent context, the algorithm being prepared, the run's lifetime    |

This folder holds the abstract type (here), Interface.jl (what every bundle type must define), Hooks.jl (what code
asks a bundle, with the answer a bundle gets by default) and one file per bundle type, which defines the type, its
Interface.jl methods and its own methods of the hooks.

Names used everywhere: `getpersistent` / `persistent_context` for the persistent context, `getruntime` /
`runtime_context` for the runtime context.
=#

"""
    ContextBundle

What a step or init works on: a persistent context plus what the phase needs besides it. A subtype per phase
(`LoopContext`, `InitContext`).
"""
abstract type ContextBundle end

include("Interface.jl")
include("Hooks.jl")
include("LoopContext.jl")
include("InitContext.jl")
