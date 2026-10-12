# exp/inline-scopes: notes and open work for agents

Branch `exp/inline-scopes` sits on `refactor/dsl-locals-rebased` (the DSL refactor; its changes go there, the
experiment goes here). Nothing is pushed. Write-up for the owner: https://claude.ai/artifact/UrageccHJ1C8G8gA734V2o

## Mistake to not repeat (2026-10-12)

The commit "no separate first step" (now 91b1685) turned a routine child's repeats into one loop,
`for i in resume_point:count`. I measured it only under `InlineProcess`, where the cursor's resume point is the
constant 1 and the compiler lays the repeats out. Under `Process` the resume point is read from a mutable box
(`PausableRoutineCursor.resume_idxs`), the loop's start is unknown while compiling, and every routine child keeps a
general loop: "3-level Routine" 0.50 -> 1.33 ns/step, "Routine in composite" 1.82 -> 3.99 under `Process`.

**Rule:** a change to how steps, repeats or schedules are generated is measured under both `InlineProcess` and
`Process` (`julia --project=perf perf/run.jl --runtime-only`, both runners are in every row), and against the
commit before it, one change at a time. A slowdown found after a commit that changes several things is isolated by
reverting one part at a time, never attributed by guess.

## Findings

- **Stored `SubContext` name (old, fixed here in 589d7f0).** `SubContext` stored `name::Symbol` next to its data,
  so a context's values were 16 bytes apart with a pointer between each. With the separate first step gone, the
  loop starts from values loaded from the context and LLVM stopped vectorizing independent updates (wide
  composite 0.058 -> 0.205 inline). Removing the field: 0.058 inline and under Process (branch Process 0.110).
  Same field on main and the branch; worth moving there.
- **Process routines (open).** Cause proven: with `get_resume_point(::PausableRoutineCursor, i) = 1` (temporary
  test) Process is at the branch's speed (0.48-0.49; 1.82). With the first repeat separate again: 0.49-0.50; 2.12-2.15.
- **Old bug: resume points are never reset to 1.** After a resume in the middle of a child's repeats, the child runs
  only the remaining repeats in every later step (`Routine(Counter, (5,))`, resume point 3: later steps run 3
  repeats, not 5). On this branch and `refactor/dsl-locals-rebased`; main has the same code (not run there).
- **flat Routine (1, 1, 1), InlineProcess (open).** 0.03 ns/step slower than branch and hand loop: the compiled loop
  does the three multiply-adds one at a time; branch and hand loop do two in one vector instruction. Ruled out:
  order of carried values, the context given to stop checks, the registry `Ref` check after the loop (a hand loop
  from memory with that check still vectorizes).

## Options for Process (owner to choose)

- A (proposed): read resume points only in the step right after a resume (a cursor that reads the recorded points
  for that one step, then clears them); every other step uses resume point 1 as a constant and still records
  points on a pause. Branch speed, fixes the reset bug.
- B: separate first repeat again (most of the speed; brings back 4 copies of a nested `@repeat` under InlineProcess).
- C: per routine child, a fast path for resume point 1 and a slow path (doubles each child's compiled code).

## How the numbers were taken

- Loop time only: runs built and compiled first, the fixed cost per run left out or shown separately.
- Per kind of core: `pthread_cpu_number_np` before and after each measurement; cores 0-5 and 6-14 differ by up to
  1.4x for the same code on this M5 Pro. Compare within one kind.
- Avoid microbenchmarks whose step writes memory the next step reads at once (`SINK[] += v`, `process.loopidx`):
  their time is decided by how soon the read follows the write (a `nop` changes it by up to 2x).
- Machine code: `code_native(run, (typeof(ip),))` (`run` inlines `loop`), IR: `code_llvm`, phi nodes show what the
  loop carries.
