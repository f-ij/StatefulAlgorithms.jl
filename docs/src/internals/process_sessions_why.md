# [Why Processes Run Through Sessions](@id process_sessions_why)

A process does not hand itself to its loop. It hands over a session (`ProcessSession`), and the plan, context and
lifetime without the plan's `UniqueKeyMap`. This page explains why these intermediates exist. In short: the loop has to
be compiled for concrete types (type stability), and those types must not change when the user makes new `Unique`
handles, or the loop is compiled again for every new set of handles. The process the user holds is typed on those
handles; the session is the part of the run that the loop can share with the process without that type.

The path through these structs is on [Process Pipeline Internals](@ref process_pipeline_internals).

## 1. The Problem: Handles in Types

`Unique(f)` makes a handle: an algorithm that is its own registry entry with its own state. Its matcher is a
`UniquePlanId{N}(origin::UUID)` (`src/Identifiable/UniquePlanId/StructDef.jl`). If the uuid were the type parameter,
every `Unique(f)` would be a new type, and so would every plan, registry and context that holds it. The same code run
again with new handles would compile its plan constructor, `resolve`, `init` and the loop again. The docstring of
`UniquePlanId` records the cost: a `Process` rebuild took 251–295 ms, against 4.7–4.8 ms with the split below.

So the uuid is data (`origin`), and the type parameter `N` changes as the handle moves:

| `N` | Set by | When | The type then |
|:--|:--|:--|:--|
| the uuid | `Unique(f)` | the user makes the handle | is a key known from its type |
| `:dynamic` | `strip_unique` | a plan constructor or DSL block takes the handle | is the same for every handle |
| `k` = 1, 2, ... | `number_unique_ids` | a plan is resolved: each new `origin` gets the next number | is the same in every rebuild of the same code |

The registry, the context, `init` and the loop only see the numbered form. Two rebuilds of the same code with new
handles give the same plan type, registry type and context type.

## 2. The Map, and Where It May Be

The user still holds the uuid form, and wants `context(p)[handle]` to be a lookup decided from types, as a registry
key is. That needs the plan's `k => uuid` pairs in a type: `UniqueKeyMap{P}`, where `P` is the tuple of pairs
(`src/Identifiable/UniquePlanId/UniqueKeyMap.jl`). `resolve` puts it into the registry's type
(`NameSpaceRegistry{E, M}`, `M` the map), and `numbered_handle` turns a held handle into its number while compiling.

`P` holds uuids, so every type that has the map in it is a new type for every set of handles, and every method
compiled for it is compiled again. The map must therefore be in the types the user's calls are compiled for, and in
none of the types the loop (or `init`) is compiled for.

That is the split: the map lives only in the registry, so the process has it in its type through its plan's registry
(`Process{F, C}`, `InlineProcess{TD, ...}`; no field of its own), and where a run is handed over (the process to its
session, the context to the loop's bundles) it is dropped (`strip_keymap`, `src/Identifiable/UniquePlanId/Accessors.jl`).

## 3. Why the Loop Cannot Take the Process

The loop needs more than the plan and the context. It writes counters (`loopidx`, `tickidx`) and times, it reads the
pause and stop flags that `pause(p)` and `close(p)` set from another task, and it keeps the cursor of a paused run. All
of that is shared with the process: the user reads `loopidx(p)` and sets the flags on the same object the loop reads.

Before sessions, those were fields of the process, and the loop took the process (`loop(process::P, ...)`). Commit
`4d04066` made both changes together: the process got `K` in its type, so the user's lookups are typed, and the loop
moved to a session, as a loop taking a process typed on `K` would be compiled again for every set of handles.

The session (`src/Sessions/`) holds exactly those fields and nothing typed on the map:

| Session | Type parameters | None of them has `K` because |
|:--|:--|:--|
| `InteractiveSession{C, LT}` | `C` the plan's cursor type, `LT` the lifetime type | the cursor is built from the stripped plan; the lifetime's `Var`s are numbered (section 5) |
| `InlineSession` | none | it holds only the counter |

The process holds the session in a field and the loop gets the same object, so the process and the loop still share
the run's record, while the loop's argument types are the same for every set of handles. The loop and the steps never
see the process.

## 4. Type Stability at the Loop's Entry

The loop is compiled for the types of its arguments: `loop(session, plan, context, lifetime, inputs, resume)`. For the
loop to be type stable, each of these must be concrete where the loop is entered. Two places make sure of that:

1. `Process` has fields of abstract type: `lifetime::Lifetime`, `paused_context` and `reshaped_context` (the context's
   type can change between runs, `commit_context!`), and `session::InteractiveSession{C}` without `LT`. `makeloop!`
   reads them and calls `_makeloop!`, which is dispatched on their types at run time: one dynamic dispatch per run,
   after which everything is typed (`src/Process.jl`).
2. `run_session_loop` (`src/Loops.jl`) is a `@noinline` call of its own, the one entry for `Process` and
   `InlineProcess`. Its arguments are the session, the stripped plan, the stripped context, the numbered lifetime and
   the inputs: no `K`. So the loop's machine code is made once for all sets of handles, while the caller (`run(ip)`,
   the `Process` task), which is typed on `K`, only calls it. No session holds the context: a context read from a
   mutable field by the loop's own function makes it root the context's pointers inside the loop (22% slower per step
   on the 3D Ising graph, 2026-11-01). Passing the context in and back out costs about 50 ns per `run(ip)` for a
   616-byte context. The
   alternative, `run(ip; inlined = Val(true))`, pastes the loop into `run(ip)`, and its machine code is then made again
   for every set of handles at the first such run (5 ms for 2 children, 36 ms for 16, per the docstring of `run(ip)`).

A run of a `Process` whose lifetime has another type gets a new `InteractiveSession{C, LT}` with the same counters
(`create_session`), so `LT` is concrete too.

## 5. Everything Else That Would Carry the Map

The same rule applies to everything else that reaches the loop or `init`:

| What | Where it would get the map | What is done instead |
|:--|:--|:--|
| the plan and its context | the registry's type, after `resolve` | `strip_keymap` before `init` and before the process stores them |
| a lifetime | its `Var`s can name held handles | numbered with the plan's numbers: `number_by_keymap_dynamic` in the untyped constructors, `number_by_keymap` (typed on `K`, decided while compiling) in `run(p; lifetime)` and `run(ip; lifetime)` |
| the constructors' keywords | Julia's keyword method specializes on the keywords' `NamedTuple`, whose type has a lifetime `Var`'s uuids | `Core.kwcall` written by hand, `@nospecializeinfer` (the comment records 2.5 ms per new set of handles before) |
| the `Process` task | a closure capturing the process | `ProcessTaskBody`, a struct whose type is known when the process is built |

## 6. What Is Still Compiled per Set of Handles

What is typed on `K` is small: the process's construction (`_construct_process`, `_construct_inline_process`), `run`,
and the calls that put the map back. These are compiled when the process is built, by `precompile_interface`
(`src/PrecompileInterface.jl`), so the first `run` does not wait for them.

What the loop gives back gets the plan's registry (`with_plan_registry`: for what `Process` keeps and `fetch(p)`, and for
`context(ip)` and `run(ip)`), so lookups with held handles stay typed on the user's side.

## 7. Summary

| Struct | Typed on `K` | Shared between | Why it exists |
|:--|:--|:--|:--|
| `Process`, `InlineProcess` | yes | the user | typed lookups with held handles; holds what lives between runs |
| `ProcessSession` (`InteractiveSession`, `InlineSession`) | no | the process and the loop | the run's mutable record (counters, times, flags, cursor) without `K`, so the loop compiles once for all sets of handles |
| the stripped plan, context, lifetime | no | the loop | the loop's arguments, concrete and without `K` |
| `run_session_loop` | no | — | the call boundary between code typed on `K` and the loop |
