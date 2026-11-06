# [User Handles and Loop Versions](@id handles_loop_versions_internals)

Three things a user holds each have a second, internal version that only the loop gets:

| User handle | Loop version | What the loop version is |
|---|---|---|
| process (`Process`, `InlineProcess`, `TimedProcess`) | session (`InteractiveSession`, `InlineSession`) | the run's counters (and, for a `Process`, its pause/close flags and times), nothing else of the process |
| plan (resolved, its registry has the plan's `UniqueKeyMap`) | loop plan | the same plan, its registry without the map (`strip_keymap`; an `InlineProcess` makes it once, `loop_algo`) |
| context (`ProcessContext`, its registry has the map) | `LoopContext` | the context without its registry (`drop_registry`: no registry reaches the loop), plus the run's runtime context (inputs, declared locals, returns) |

A run makes all three in one place, `prepare_for_loop(owner, context, inputs, resume) -> (session, loop_plan,
loop_context)` (src/Processes/Hooks.jl), the first call of every run entry (`run(p)`, `run(ip)`, `run(plan, context)`,
the manager's inline run). On the way back the loop's values go into the context the process keeps, which keeps its
registry with the map (`_sync_state_context!`), or the plan's registry is put on the result again
(`with_plan_registry`, `with_keymap`).

Both versions are needed, for two reasons that pull against each other:

1. **The handles are for the user.** They hold everything needed to build around the package: run a process, or use a
   plan and a context without a process (`setup`, `run(plan, context)`), read and write a context (`ctx[handle]` is
   decided while compiling because the map is in the registry's type), and later run a plan inside the user's own
   loop. A context then works like a nested `NamedTuple`, and a plan like a function that takes one and returns the
   changed one, with no overhead.
2. **The loop needs none of that.** What makes 1. work slows the loop down: the map in the types gives every new set of
   `Unique` handles new types, so everything typed on them compiles again, and the process's own fields would sit in
   the loop. Without them the loop is compiled once for every set of handles and carries only what its steps read.

So the stripping happens where a run is handed to the loop (`prepare_for_loop`; an `InlineProcess` strips its plan once
when it is built, `loop_algo`), and where `init` runs (`setup`, `init(plan, context, ...)`), and nowhere else: the handles keep the map on purpose. The map lives only in registries;
a process has no field of its own for it.
