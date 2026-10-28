# [Registry Internals](@id registry_internals)

The registry layer is what assigns stable subcontext names to algorithms/states and makes value/type lookups predictable.

Core types:

- `NameSpaceRegistry`: top-level registry (`src/Registry/StructDef.jl`).
- `RegistryTypeEntry{T}`: one partition per entry type
  (`src/Registry/TypeEntries/StructDef.jl`).
- `IdentifiableAlgo{F,Id,...,Key}`: wrapped process entity with identity and assigned context key (`src/Identifiable/StructDef.jl`).

## 1. Type Partitions and Matching

Entries are grouped by `assign_entrytype(obj)` (`src/Registry/Traits.jl`).

- Default entry type: the object's type wrapper.
- `IdentifiableAlgo` overrides this via `registry_entrytype(::Type{<:IdentifiableAlgo{T}}) = T` (`src/Identifiable/IdentifiableAlgos.jl`).

Within each `RegistryTypeEntry`, matches use `match_by` (`src/Matching.jl`, `src/ProcessEntities/Matching.jl`):

- Process entity instance (`Fib()`): direct immutable instances match by value; other instances match by object identity.
- Process entity type (`Fib`): matches by type (`match_by(::Type{<:ProcessEntity}) = T`).

This is why instance-based and type-based registrations are distinct identities.

## 2. Key Assignment

`add(reg, obj, multiplier)` (`src/Registry/Registries.jl`,
`src/Registry/TypeEntries/Adding.jl`) does:

1. Find/create the correct `RegistryTypeEntry`.
2. If no match exists, create a key with `Autokey` (`TypeName_index`) and wrap as `IdentifiableAlgo`.
3. If a match exists, reuse the existing key and increase multiplier.

Key consequences:

- Same value entered repeatedly: same key reused.
- Same type entered repeatedly: same key reused for that type identity.
- Type-entered value vs value-entered value can still be different identities.
- This stays true across nested `CompositeAlgorithm`/`Routine` trees because `setup_registry` flattens all entities into one registry pass before context creation.

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
| 2 | `ValueId` | `strip_unique` | a constructor or DSL block takes the handle: the same type for every handle |
| 3 | `k` = 1, 2, ... | `number_unique_ids` | a plan is built: each new uuid gets the next number; a nested plan is renumbered by uuid |

1. Every holder of an id keeps it as a value next to its type, so both rewrites (strip and number) reach it: a handle in
   its `matcher` field, a route in its endpoint fields, a `Var` in its `matcher` field. A `Var`'s type parameter is
   that field's type, so the rewrite updates it with the field. The other holders also copy the id into a separate
   type parameter, which is worked out again from the field (`list_field_derived_params`).
2. A plan's schedule (a `Routine`'s lifetimes, a composite's intervals, which may hold `Var`s) is a field; the plan's
   type has only the schedule's type, in which an id is `UniquePlanId{k}`: which handle within the plan.
3. The registry stores each handle numbered, as the plan has it.
4. `resolve` puts the plan's `UniqueKeyMap` (`k => uuid` pairs) into the registry's type (its `keymap`,
   `src/Identifiable/UniquePlanId/UniqueKeyMap.jl`). `registry[handle]`, `getkey(registry, handle)` and `context[handle]` with
   a handle the user holds number it from that map while compiling (`numbered_handle`) and look it up from types, as
   a registry key.
5. Running the plan takes the map out (`strip_keymap`): `init`, `run(la)`, `Process`, `InlineProcess` and
   `TimedProcess` resolve the plan untyped and prepare the plan and its context without the map, so `init` and the
   loop have no uuid in their types and compile once for every new set of `Unique`s. `Process` and `InlineProcess`
   hold the map in their own type (`keymap::K`, zero bytes); the loop and the steps get a session instead of the
   process (`ProcessSession`, `src/Sessions/`), reached through `run_session_loop`, whose arguments have no map, so
   the loop is compiled once for every set of `Unique`s (`run_session_loop!` for an `InlineProcess`, on the context
   its session holds).
6. What a process hands back has the map put back: `context(ip)` builds it typed (`attach_keymap`); a `Process`
   builds the user's context once each time its context changes (`set_user_context!`, after a run in `_finish_run!`)
   and `context(p)` reads it; `fetch(p)` and the plan `init` and `run(la)` return have it too (`with_keymap`). A
   context given back to SA has it stripped: `Process(...; context)` (`strip_keymap`),
   `context(ip, c)`, `run(ip; context)` (`detach_keymap`, typed).
7. A lifetime given to a process or a run is not part of the plan: its `Var`s get the plan's numbers when it is given,
   so the loop finds them while compiling: while compiling for a typed handle (`number_by_keymap`: `run(ip;
   lifetime)`, `run(p; lifetime)`, a manager's per-job lifetime), at run time at the untyped entry points
   (`number_by_keymap_dynamic`: `Process(...; lifetime)`, `InlineProcess(...; lifetime)`, `init`/`run(la)`).

The matching and registry code ask a matcher only general questions (`matches_type`, `is_given_id`, `is_found_by_data`,
`lower_matcher`, `carries_data`); `UniquePlanId` answers them in `src/Identifiable/UniquePlanId/HookExtensions.jl`. A
holder says which of its type parameters come from its fields with `list_field_derived_params`
(`src/Identifiable/UniquePlanId/Hooks.jl`). A plan's schedule is changed only through `setschedule`
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

- `Type`, direct immutable values, and `AbstractIdentifiableAlgo` values use the static lookup path.
- other values use the dynamic lookup table keyed by `match_by(obj)`.

So direct immutable instances can match equal values, while ordinary mutable
instances match by object identity. `Unique(...)` gives an explicit fresh
identity when the default rules are not what you want.

## 5. Multipliers

Each registry entry tracks a multiplier (`RegistryTypeEntry.multipliers`).

For loop algorithms this is derived from composition structure (intervals/repeats), and is used by utilities such as `processsizehint!`/`num_calls` (`src/Tools.jl`).

## 6. Order Guarantees

`setup_registry` adds:

1. `AlgoState`s first.
2. Then flattened algorithms.

(see `src/LoopAlgorithms/ConstructorCommon.jl`)

That ordering controls init/cleanup traversal order through `all_algos(registry)`.
