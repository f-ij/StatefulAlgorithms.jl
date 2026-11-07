# [Registry Internals](@id registry_internals)

The registry layer is what assigns stable subcontext names to algorithms/states and makes value/type lookups predictable.

Core types:

- `NameSpaceRegistry`: top-level registry (`src/Registry/StructDef.jl`).
- `RegistryTypeEntry{T}`: one partition per entry type
  (`src/Registry/TypeEntries/StructDef.jl`).
- `IdentifiableAlgo{F,Id,...,Key}`: wrapped process entity with identity and assigned context key (`src/Identifiable/StructDef.jl`).

## 1. Type Partitions and Matching

Entries are grouped by `assign_entrytype(obj)` (`src/Registry/Interfaces.jl`).

- Default entry type: the object's type wrapper.
- `IdentifiableAlgo` overrides this via `registry_entrytype(::Type{<:IdentifiableAlgo{T}}) where {T} = T` (`src/Identifiable/IdentifiableAlgos.jl`); `Package` and `ContextExchange` have their own.

Within each `RegistryTypeEntry`, matches use `match_by` (`src/Matching.jl`, `src/ProcessEntities/Matching.jl`):

- Process entity instance (`Fib()`): direct immutable instances match by value; other instances match by object identity.
- Process entity type (`Fib`): matches by type (`match_by(::Type{<:ProcessEntity}) = T`).

This is why instance-based and type-based registrations are distinct identities.

## 2. Key Assignment

Algorithms are added to a `RegistryBuilder` with `add!(builder, obj, multiplier)`, and `registry(builder)` builds the
`NameSpaceRegistry` at the end (`src/Registry/Builder.jl`; `add(reg, obj, multiplier)` does the same on a finished
registry). Adding:

1. Find/create the entry for the object's entry type.
2. If no match exists and the object has a given key (an `@alias`, a named state, `rename`) that a different algorithm
   already has, it is an error ("rename one of them first", `check_key_unused`). States and algorithms are matched by
   their id, never by name; making two states one is `@merge`.
3. If no match exists, create a key with `Autokey` (`TypeName_index`) and wrap as `IdentifiableAlgo`.
4. If a match exists, reuse the existing key and increase multiplier.

Key consequences:

- Same value entered repeatedly: same key reused.
- Same type entered repeatedly: same key reused for that type identity.
- Type-entered value vs value-entered value can still be different identities.
- This stays true across nested `CompositeAlgorithm`/`Routine` trees because the whole tree is added to one `RegistryBuilder` in one walk before context creation (`build_registry_and_key_plan`, step 1 of `resolve`, `src/GeneratedCode/Registry/Setup.jl`; the walk on values is in
`src/LoopAlgorithms/Resolving/Registering.jl`).

## 3. `Unique` and Distinguishability

`Unique(f)` builds an `IdentifiableAlgo` with a fresh UUID identity: its matcher is `UniquePlanId{uuid}(uuid)`
(`src/Identifiable/UniquePlanId/`), kept as data in the handle's `matcher` field, with its type in the handle's type.

That gives a guaranteed distinct match identity even when the wrapped value is otherwise indistinguishable.

What it solves: a uuid in a type makes every `Unique(f)` a new type, so the same code built again with new handles
compiled its plan constructor, `resolve`, `init` and the loop again (a `Process` rebuild compiled 251–295 ms; with the
steps below 4.7–4.8 ms). So the uuid (`origin`) is data and never changes; the type holds `N`, which three functions set:

| # | `N` | Set by | When |
|---|---|---|---|
| 1 | the uuid | `Unique(f)` | the user makes the handle: a key known from its type |
| 2 | `:dynamic` | `strip_unique`; `DynamicUnique(f)` | a constructor or DSL block takes the handle; a DSL block makes its own `@state`: the same type for every handle |
| 3 | `k` = 1, 2, ... | `number_unique_ids` | a plan is resolved: each new uuid gets the next number |

1. Every holder of an id keeps it as a value next to its type: a handle in its `matcher` field, a route in its endpoint
   fields, a `Var` in its `matcher` field. Stripping, numbering and mapping are each one
   `map_matchers_of_type(UniquePlanId, x, f)` (`src/Matching.jl`): every type that holds ids, or holds values that do (a
   plan, its wiring, a `RunIf`, a lifetime), has its own method and rebuilds itself with the new ones, so its type
   follows them (a handle through `setmatcher`, a route works its endpoint matchers out again).
2. A plan's schedule (a `Routine`'s lifetimes, a composite's intervals, which may hold `Var`s) is a field; the plan's
   type has only the schedule's type, in which an id is `UniquePlanId{k}`: which handle within the plan.
3. The registry stores each handle numbered, as the plan has it.
4. `resolve` puts the plan's `UniqueKeyMap` (`k => uuid` pairs) into the registry's type (its `keymap`,
   `src/Identifiable/UniquePlanId/UniqueKeyMap.jl`). `registry[handle]`, `getkey(registry, handle)` and `context[handle]` with
   a handle the user holds number it from that map while compiling (`numbered_handle`) and look it up from types, as
   a registry key.
5. The map lives only in registries. Plans and contexts the user gets keep it: the contexts of `setup`,
   `run(plan, context)` and `init(plan, context, ...)`, and a process's plan and context (`getalgo(p)`, `getcontext(p)`,
   `fetch(p)`); a process has no field of its own for it. Running the plan takes it out (`strip_keymap`): `setup` and
   `init(plan, context, ...)` run `init` without it, and `prepare_for_loop` gives the loop the plan without it and a
   `LoopContext` whose context has no registry at all (`drop_registry`), so `init` and the loop have no uuid in their
   types and compile once for every new set of `Unique`s. What the loop gives back goes into the context the user or the
   process keeps, which keeps its registry (`_sync_state_context!`, `withsubcontexts` in `run(plan, context)`), or gets
   the plan's registry back (`with_plan_registry`). SA's own code that needs a process's context without the map
   outside the loop reads `_getcontext_nokeymap(p)`.

The matching and registry code ask a matcher only general questions (`matcher_equals`, `dynamic_equals`,
`lower_to_lookupkey`, `carries_data`), always on matcher values, never on a matcher's type; `UniquePlanId` answers them in `src/Identifiable/UniquePlanId/HookExtensions.jl`. A
holder rebuilds itself with new matchers in its own `map_matchers_of_type` method. A plan's schedule is changed only through `setschedule`
(`src/LoopAlgorithms/ParameterReplacement.jl`).

This is the mechanism used when you need multiple logically separate instances of the same algorithm in one composition.

## 4. Lookup Behavior

`ProcessContext` lookups by value/type eventually call registry `getindex` (`src/Context/ProcessContexts.jl`, `src/Registry/Registries.jl`).

The registry also supports direct symbol-key lookup:

- `reg[:Fib_1]` returns the registered `IdentifiableAlgo`

That is the same key space used by:

- `resolved[:Fib_1]` on resolved loop algorithms
- `ctx[:Fib_1]` on process contexts

Important runtime detail in `NameSpaceRegistry.getindex`:

- `reg[obj]` first numbers a held `Unique` handle by the registry's `UniqueKeyMap` (`number_held_handle`), then finds
  the entry of `obj`'s entry type and, in it, the first algorithm `obj` matches (`findfirst_match`): decided while
  compiling when the types decide it, otherwise at run time.
- the entries' runtime lookup tables are kept, but no lookup uses them.

So direct immutable instances can match equal values, while ordinary mutable
instances match by object identity. `Unique(...)` gives an explicit fresh
identity when the default rules are not what you want.

## 5. Multipliers

Each registry entry tracks a multiplier (`RegistryTypeEntry.multipliers`): how often the algorithm runs per run of the
root plan.

For loop algorithms this is derived from each plan's schedule: `multipliers(plan)` maps the hook
`compute_multiplier(entry)` (`src/LoopAlgorithms/Hooks.jl`) over `getschedule(plan)` (an interval `n` gives `1/n`, a
repeat count `n` gives `n`), multiplied down the tree. It is used by utilities such as `processsizehint!`/`num_calls` (`src/Tools.jl`).

## 6. Order Guarantees

The registry walk (`build_registry_and_key_plan`, and `setup_registry` in `src/LoopAlgorithms/ConstructorCommon.jl`) adds:

1. `AlgoState`s first.
2. Then flattened algorithms.

(see `src/LoopAlgorithms/Resolving/Registering.jl`)

That ordering controls init/cleanup traversal order through `all_algos(registry)`.
