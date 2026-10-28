# Process files: folder layout and InlineProcess cleanup

Found 2026-10-28 on `refactor/plan-compiles` (ca5b1d1) by reading `src/InlineProcess.jl`,
`src/InlineProcessShowing.jl`, `src/Process.jl`, `src/ProcessInteraction.jl` and `src/ConstructorCommon.jl` and
grepping callers; nothing was run or changed. `InlineProcess.jl` repeats what `Process` already does, and the process
types are loose files at the top of `src/`.

Suggested order: first the moves (layout below) with `git mv`, as their own commit, so history follows the files and the
cleanup diff shows only real changes; then 1-8; verify 9 before deleting; tests after each step.

## Layout (agreed with the owner)

```
src/Processes/
  AbstractProcess.jl   (from src/AbstractProcesses/AbstractProcesses.jl)
  Interface.jl         (from src/AbstractProcesses/Interface.jl)
  Common/              Construct.jl (src/ConstructorCommon.jl + 1, 3), Showing.jl (8)
  Process/             Process.jl (struct + constructor), Context.jl, Loop.jl, Interaction.jl (ProcessInteraction.jl),
                       Status.jl (ProcessStatus.jl), List.jl (ProcessList.jl), Copy.jl, Showing.jl
  InlineProcess/       InlineProcess.jl (struct + accessors), Construct.jl, Context.jl, Run.jl, Showing.jl
                       (from InlineProcessShowing.jl)
```

Keep today's include order in `src/StatefulAlgorithms.jl`: `AbstractProcesses/` before `Sessions/` (lines 33, 43), the
process files after `Listeners.jl` (lines 73-87). Include the new paths at those same points rather than one
`Processes.jl`, which would hide the order.

Open for the owner:
- `src/Manager/` (`ProcessManager`) is not `<: AbstractProcess`; suggestion: leave it where it is.
- `src/TimedProcess.jl` is not included anywhere, so it is never built: delete, or move to `Processes/TimedProcess/` with
  a TODO?

## Fix

1. "`repeats` or `lifetime`" three times: `_inline_process_lifetime` (`InlineProcess.jl:39`),
   `_process_constructor_lifetime` (`Process.jl:125`), `_process_run_lifetime` (`ProcessInteraction.jl:10`). Each
   checks only one is given, then `normalize_process_lifetime`; they differ in the default and in allowing `repeat` /
   a positional lifetime. One function in `Common/Construct.jl`, the default as an argument.
2. `_prepare_inline_process` normalizes the lifetime twice (`InlineProcess.jl:80-81`): `_inline_process_lifetime`
   already returns it normalized; the second `normalize_process_lifetime` is a no-op.
3. `_build_inline_process` and `_build_process` (`Process.jl:165`) share their first steps: `normalize_process_algo`,
   `resolve`, `getkeymap`, `strip_keymap` + `number_by_keymap_dynamic`. One untyped
   `resolve_for_process(func, context, lifetime) -> (algo, context, lifetime, keymap)` for both. The hand-written
   `Core.kwcall` stays per type, but its comment is copied word for word; say it once.
4. `run_nogen` (`InlineProcess.jl:189`) is `run` with `threaded = false`, `inlined = Val(false)`, checking inputs and
   lifetime in the other order. Callers: `src/Precompile.jl:667, 672`, `test/InlineBenchmarkTest.jl:45`,
   `test/RuntimeInputsLifecycleTest.jl:159`. Delete it; callers use `run(ip; threaded = false)`.
5. Two ways to set the context: `context(ip, c)` (`InlineProcess.jl:104`) and `_set_inline_run_context!` (`:152`) both
   `strip_keymap_typed` and `set_session_context!`; only the second asserts the type. Keep one, with the assert.
6. The mode is a type parameter (`Mode`), but `_inline_process_mode_label` (`InlineProcessShowing.jl:1`) rebuilds it
   from `isthreaded`/`isasync`. One accessor `execution_mode(ip) = Mode`; `isthreaded`/`isasync` and the show methods
   use it.
7. `getcontext(ip) = context(ip)` (`InlineProcess.jl:99`) and `getcontext(p::Process) = context(p)` (`Process.jl:290`):
   one `getcontext(p::AbstractProcess)` in `Processes/Interface.jl`.
8. `_inline_process_algo_summary` (`InlineProcessShowing.jl:11`) is `_process_algo_summary` (`Process.jl:60`). The tree
   helpers both show methods use (`_process_nested_show_lines`, `_process_context_show_lines`,
   `_print_process_nested_field`, `Process.jl:64-123`) live in `Process.jl`; move them to `Common/Showing.jl`.

## Verify before deleting (grep only so far)

9. Unused?
   1. The `consumed` field of `InlineProcess`: written in `reset!` (`InlineProcess.jl:134`, with "TODO: Probably remove
      consumed flag"), no reader found.
   2. `init_and_run(::InlineProcess)` (`InlineProcess.jl:212`): no callers found.

   Check with the compiled-method listing, entry points and a probe before removing.

## Small

10. `InlineProcess.jl` ends in a whitespace-only line, and exports `run` and `reset!` (`run` is `Base.run`).
