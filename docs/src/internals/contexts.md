# [Context Internals](@id context_internals)

The runtime data stack has three layers:

1. `ProcessContext`
2. `SubContext`
3. `SubContextView`

## 1. `ProcessContext`

`ProcessContext{D,R}` stores two values (`src/Context/StructDefs.jl`):

1. `subcontexts::D`, a named tuple of `SubContext` values.
2. `reg::R`, the registry used for identity lookup.

The initialized process owns a persistent `ProcessContext`. Loop execution also
builds a separate runtime `ProcessContext`, normally with `:_runtime` and
`:_input` subcontexts. Runtime inputs, the active process/lifetime handles, and
demanded transient step returns live there instead of changing persistent state
shape.

Persistent contexts support these lookup forms:

1. `pc[:name]` or `pc.name` selects a subcontext by symbol.
2. `pc[obj]` resolves an algorithm or state reference through `reg` and selects
   its subcontext.

`getglobals(runtime_context)` returns the data in `:_runtime`, while
`getruntimeinput(runtime_context)` returns the data in `:_input`. If those
subcontexts are absent, the corresponding accessor returns an empty named tuple.

## 2. `SubContext`

`SubContext{Name,T}` stores (`src/Context/StructDefs.jl`):

1. `name::Symbol`, also represented by the `Name` type parameter.
2. `data::T`, the entity-owned `NamedTuple`.

Initialization first makes an empty subcontext for each registry entry. Each
entity's `init` result then replaces its subcontext and establishes its
persistent field names and types.

Route/share metadata is deliberately absent from `SubContext`. Resolved plan
wiring is supplied only while a child executes, so the persistent context shape
does not depend on execution-plan wiring.

## 3. `SubContextView`

`step!`, `init`, and `cleanup` receive a `SubContextView`
(`src/Context/View/StructDef.jl`). A view carries:

1. the persistent context;
2. the separate runtime context;
3. the current identifiable instance or namespace;
4. explicitly injected values; and
5. type-specialized aliases, shared contexts, and routed variables.

Property access is compiled to `VarLocation` values. When the same local name is
available from more than one source, precedence from lowest to highest is:

1. shared-context fields;
2. routed fields;
3. local fields; and
4. injected fields.

Thus local fields occlude route/share names, and injected fields occlude all
other sources.

## 4. Merging Lifecycle Returns

During `init`, the returned named tuple replaces the current entity's empty
subcontext. During `step!`, generated merge code treats returned names in two
ways:

1. A name with a `VarLocation` writes to its mapped persistent field, including
   routed/shared writeback and replacement redirection.
2. An unknown name is written only to the owner bucket in the runtime context
   when current plan wiring or the root finalizer demands it. Otherwise it is
   discarded.

`cleanup` also commits mapped persistent writes. Its unknown returns are kept in
the runtime context long enough for the root final-result projection to see
them, but they are not added to the stored persistent context.

After mapped writes, generated code asserts that the persistent
`ProcessContext` type is unchanged. This rejects field-type changes that would
make the loop state type-unstable. Runtime-only returns are merged separately and
are removed from the stored process context after loop finalization.
