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

- **Stored `SubContext` name (old, fixed here in 589d7f0).** `SubContext` had a field `name::Symbol` (filled from
  the type parameter), so each subcontext was 16 bytes and the 32 values of the wide composite were 16 bytes apart.
  It is the spacing, not the pointer: with the field replaced by an `Int` the loop still did not vectorize. LLVM
  vectorizes the loop only if packing the starting values into vector registers is cheap enough; its estimate covers
  one pass through the code, not the iterations. Spaced values need one load and insert each. On the branch the
  separate first step put a second copy of the arithmetic into that pass and tipped the estimate (its IR builds the
  vector with 32 `insertelement`s, then runs the first step and the loop as `<32 x double>`). Not an inference
  problem: all values concrete, 0 allocations, before and after. 0.205 -> 0.058 inline, 0.176 -> 0.058 Process.
- **Process routines (open).** Cause proven: with `get_resume_point(::PausableRoutineCursor, i) = 1` (temporary
  test) Process is at the branch's speed (0.48-0.49; 1.82). With the first repeat separate again: 0.49-0.50; 2.12-2.15.
- **Old bug: resume points are never reset to 1.** After a resume in the middle of a child's repeats, the child runs
  only the remaining repeats in every later step (`Routine(Counter, (5,))`, resume point 3: later steps run 3
  repeats, not 5). On this branch and `refactor/dsl-locals-rebased`; main has the same code (not run there).
- **flat Routine (1, 1, 1), InlineProcess (explained, left as is).** 0.03 ns/step: the loop is not vectorized because
  its values must survive the clock calls around it (`set_starttime!` after `run` read the context, `set_endtime!`
  before the write-back). On this AArch64 hardware only the low 64 bits of a few vector registers survive a call, so
  a vector would be saved and reloaded; LLVM counts that. Proven: removing both clock calls vectorizes it (1.00-1.01x
  hand); a hand loop with one clock call after it stops vectorizing. Taking the start time before the context is
  read fixes it, but makes LLVM vectorize "Routine in composite" too, which gets slower there (1.80 -> 2.2 ns: two
  dependent update chains of different length paired in one vector), so that change was not kept.
  **Correction:** an earlier note blamed the registry pointer and the write barrier; wrong (removing the write-back
  changed nothing).

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
