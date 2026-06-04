# [Context Internals](@id context_internals)

The runtime data stack is:

1. `ProcessContext`
2. `SubContext`
3. `SubContextView`

## 1. `ProcessContext`

`ProcessContext{D,Reg}` holds (`src/Context/StructDefs.jl`):

- `subcontexts::D`: named tuple of subcontexts plus `globals`.
- `registry::Reg`: a `NameSpaceRegistry` used for static routing and lookup.

Access patterns (`src/Context/ProcessContexts.jl`):

- `pc[:name]` or `pc.name` by subcontext symbol.
- `pc[obj]` by algorithm/state value/type (resolved through registry key).

`globals` is a regular field in `subcontexts`; runtime code injects process-level values there (like `process`, `lifetime`, `algo`).

## 2. `SubContext`

`SubContext{Name,Data}` stores (`src/Context/StructDefs.jl`):

- `data::NamedTuple`: local variables owned by that entity.

Initialization builds empty `SubContext`s for every registry key, then fills them by `init`.

Route/share metadata is deliberately not stored on `SubContext`. Plan routing is
resolved into step-local `StepRouting` values and attached to `SubContextView`
types while a child runs. This keeps persistent context shape independent from
execution-plan wiring.

## 3. `SubContextView`

`step!`, `init`, and `cleanup` run against a `SubContextView` (`src/Context/View/StructDef.jl`).

A view carries:

- the full context,
- the current identifiable instance,
- optionally injected locals.
- route/share metadata for the current step, as type parameters.

Property access is generated through `VarLocation`s (`src/Context/View/Locations.jl`):

- local vars,
- shared-context vars from the current step routing,
- routed vars from the current step routing,
- injected vars.

Name precedence for reads is determined by `NamedTuple` merge order. Later
groups override earlier groups:

1. injected vars
2. local vars
3. routed vars
4. shared vars

This means local and injected names override route/share names on collisions.

## 4. Merging and Replacing

`merge(view, namedtuple)` (`src/GeneratedCode/SubContextView.jl`) maps return names back to concrete target subcontexts and variables.

- Existing mapped variable: update that mapped target.
- Unknown variable: added to the current local subcontext.

`replace(view, (;SubKey => nt))` replaces the full subcontext and is used during init.

`merge_into_subcontexts` (`src/Context/ProcessContexts.jl`) enforces that subcontext structure remains valid.

A type-change guard in generated merge asserts the new `ProcessContext` type stays identical, preventing accidental type instability.
