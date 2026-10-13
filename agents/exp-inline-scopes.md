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
  Mechanism (2026-10-13): the SLP vectorizer starts from the loop's 32 phis and follows their inputs. Without the
  first step those are 32 spaced loads: total cost 0 ("List vectorization was possible but not beneficial with
  cost 0 >= 0"), so nothing. With the first step they are its multiply-adds, which also vectorize: cost < 0.
  Confirmed with -print-changed: the <32 x double> appears after SLPVectorizerPass. Tested in the package with the
  field put back (2026-10-13): before the loop, `0.0 + x` or `x * one + zero` (values read at run time) leave it
  scalar; `x * 0.999 + 1.0` (constants) or one full step make it vectorize (6.59 -> ~1.95 ns/step). So it is not
  about the loop starting from a prepared variable, but about enough constant arithmetic before it. `@simd` tried: no effect on a
  hand-written reproduction, and rejected on the package's step loop (it contains a `break`).
  The field removal is now on main (b30f4a5, pushed); this branch's commit "a SubContext stores no name; one stop
  check per routine repeat" only holds the routine part after the rebase.
- **Process routines (cause found 2026-10-13).** `tick!(p::Process)` does `p.tickidx += 1` on every routine repeat.
  In the code `run(p)` actually runs (the closure `Threads.@spawn loopfunc(p, ...)` in `_makeloop_prepared!`), LLVM
  writes `tickidx` to memory and reads it back on every repeat (`ldr/add/str [p, #tickidx]`); in a direct call of the
  same `loop` with the same arguments it keeps the counter in a register. A store followed by a reload of the same
  address on every repeat is the slow pattern (as `SINK[] += v`): 13.5 vs 4.9 ns/step (3-level Routine, Process).
  Proven: `tick!` as a no-op -> 5.1 ns/step through `run(p)`. Happens only with the resume point read from the
  cursor's box; with it fixed to 1 the counter stays in a register. Fully inferred: the closure's only non-concrete
  values are `p.task` and the `return`, outside the loop. Why LLVM promotes the counter in the direct call and not
  in the closure is not established.
  **Measuring mistake to not repeat:** calling `loop` directly on a finished Process leaves `shouldrun == false`, so
  every routine stop check stops early and the run does less work. Set `@atomic p.shouldrun = true` first, or time
  `run(p); wait(p)` on a new Process as the perf suite does. Equal final values are no proof of equal work when the
  values converge (`x = 0.999x + k`).
  Why (2026-10-13): LLVM keeps `p.tickidx` in a register only if it may read it before the loop (pointer known
  dereferenceable) or an access is guaranteed before any exit. Direct call: `p` is an argument marked
  `nonnull dereferenceable(192)`, so yes. In `run(p)`'s task closure `p` is loaded from the closure without that
  information, so it needs a guaranteed access: the branch's separate first repeat always does `tick!`; the single
  loop's stop check can exit before the first `tick!` (LLVM does not see that the first pass skips it). Fix tested:
  the task calls `loop` as a `@noinline` function (`_loop_as_function`), so `p` is an argument: 4.86 ns/step with
  the single loop and the resume point unchanged.
  Follow-up (2026-10-13), measured: `tick!` moved to the top of each repeat (before the stop check; the stop path
  subtracts it again so counts stay exact): 13.3-13.5 -> 5.9-6.1 ns/step; the task code still stores `tickidx` each
  repeat but reloads it less (11 vs 14 instructions touch it). `_loop_as_function` on the whole perf suite (two
  alternating rounds each): Process "3-level Routine" 1.35 -> 0.49 ns, "Routine in composite" 3.90 -> 1.82, every
  other row (Process and inline) within 0.97-1.02x. II under Process (`run(p); wait(p)`, Metropolis and LocalLangevin,
  top loop and `@repeat` routine, ~30 ns/step): within 1-3%, no clear change. SA tests pass with it. Not committed.
  "composite in Routine" under Process (7.1 vs 4.8 ns inline) is not fixed by either: a separate cause, not looked at.
  Earlier explanation "the compiler builds a loop per child" was wrong: valid direct timings show that costs ~2-10%.
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
