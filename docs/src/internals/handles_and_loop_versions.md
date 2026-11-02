# User handles and loop versions

Three things a user holds each have a second, internal version that only the loop gets:

| User handle | Loop version | What the loop version is |
|---|---|---|
| process (`Process`, `InlineProcess`) | session (`InteractiveSession`, `InlineSession`) | the run's counters (and, for a `Process`, its pause/close flags and times), nothing else of the process |
| plan (resolved, its registry has the plan's `UniqueKeyMap`) | loop plan | the same plan type, with the map stripped from its registry |
| context (`ProcessContext`, its registry has the map) | `LoopContext` | the context with the map stripped, plus the run's runtime context (inputs, declared locals, returns) |

A run makes all three in one place, `prepare_loop(owner, inputs, lifetime, resume) -> (session, loop_plan,
loop_context)` (src/AbstractProcesses/Hooks.jl), the first call of every run entry (`run(p)`, `run(ip)`, `run(plan)`,
the manager's inline run). `run(plan)` drops the plan's map at its entry, before `prepare_loop`, so that its own
untyped setup also compiles once. On the way back the plan's registry is put on the result again
(`with_plan_registry`, `with_keymap`).

Both versions are needed, for two reasons that pull against each other:

1. **The handles are for the user.** They hold everything needed to build around the package: run a process, or use a
   plan and a context without a process, read and write a context (`ctx[handle]` is decided while compiling because the
   map is in the registry's type), and later run a plan inside the user's own loop. A context then works like a nested
   `NamedTuple`, and a plan like a function that takes one and returns the changed one, with no overhead.
2. **The loop needs none of that.** What makes 1. work slows the loop down: the map in the types gives every new set of
   `Unique` handles new types, so everything typed on them compiles again, and the process's own fields would sit in
   the loop. Without them the loop is compiled once for every set of handles and carries only what its steps read.

So the stripping happens exactly once, where a run is handed to the loop, and nowhere earlier: the handles keep the map
on purpose. Planned on top of this (TODO.md): an optional Accessors.jl extension to get and set values in a context, and
running a plan without a process (an on-demand session inside the user's own loop).
