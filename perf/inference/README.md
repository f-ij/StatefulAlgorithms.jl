# Making `resolve` inferable

`resolve(plan)` used to infer as `Any`, so everything computed from it was compiled from untyped values. JET (`JET.report_opt`) found the causes:

1. `add_algo_tuple_to_registry` called itself on the tail of the children while the registry type grew at each level. Inference widens a
   growing argument in a recursive call, so the registry became plain `NameSpaceRegistry` and everything after it was a runtime dispatch.
   It now threads `(registry, children, namespaces)` through `Base.afoldl`, which Julia writes out explicitly for up to 31 elements.
2. `_resolve_plan_wiring_tree` captured `la` in a closure and then reassigned `la`. A captured variable that is reassigned is boxed
   (`Core.Box`), so every use of it was `Any`. The rebuilt value now has its own name.
3. The same function used `ntuple(length(...)) do i`, whose index is not a compile-time constant; it now uses `ntuple(Val(length(...)))`.
4. `_root_loop_options` built the options tuple from a `Vector{Any}` with `Tuple(vector)`, whose type depends on runtime data. Small option
   tuples are now filtered by type (`filter` on a tuple, up to 31 elements) and the tree walk is tuple recursion without an accumulator; the loop version
   stays for large option lists, as before.

Result for `Base.return_types(resolve, (typeof(plan),))` and JET reports (runtime dispatch etc.), `infer_shapes.jl`:

| plan shape | before | after |
|---|---|---|
| plain: two `Unique` copies and a `Tally` | `Any`, 40 reports | concrete, 0 reports |
| with a `Share` | `Any` | concrete, 0 reports |
| nested `CompositeAlgorithm` | `Any` | concrete, 0 reports |
| `Routine` | `Any` | concrete, 0 reports |
| with a `Route` | `Any` | not concrete, 17 reports |
| `Routine` with a `Route` | `Any` | not concrete, 17 reports |
| composite of a `Routine` and an algorithm | `Any` | not concrete, 41 reports |

Cold compile of the resolve pipeline (entry + construct + resolve), microseconds, five fresh processes each (min / median / max).
Raw lines: `cold_before_raw.txt`, `cold_after_raw.txt`.

| version | layout | before | after |
|---|---|---|---|
| today (random ids, no entry) | plain | 385 186 / 439 315 / 460 803 | 196 306 / 202 991 / 219 304 |
| today | route | 495 435 / 544 120 / 573 380 | 232 056 / 240 784 / 241 983 |
| entry with `@nospecialize` | plain | 462 126 / 519 930 / 575 379 | 258 023 / 262 771 / 271 526 |
| entry with `@nospecialize` | route | 554 410 / 645 719 / 650 601 | 296 462 / 305 743 / 308 798 |
| fixed ids by hand | plain | 384 412 / 401 234 / 445 519 | 191 197 / 200 927 / 225 821 |
| fixed ids by hand | route | 488 901 / 517 971 / 582 394 | 230 637 / 239 943 / 286 093 |

Median per phase, before to after: `resolve` 223 138 to 0 (plain) and 307 663 to 17 686 (route); `construct` about 216 000 to 203 000 (plain).
`plain` is two `Unique` counters and a `Tally`, nothing connected; `route` adds a `Reader` that takes its input from the second counter through a `Route`.
The test suite (860 tests) passes with these changes.

## Warm: same layout, new uuids (the resolve pipeline: entry + construct + resolve)

Microseconds, median of 8 calls (min to max wall time), compile time and wall time. Raw lines: `phases_before_raw.txt`, `phases_after_raw.txt`.

| version | layout | before: compile / wall | after: compile / wall |
|---|---|---|---|
| today (random ids, no entry) | plain | 290 420 / 291 113 (273 496 to 307 419) | 111 708 / 112 163 (109 100 to 124 250) |
| today | route | 356 875 / 357 720 (344 552 to 365 002) | 149 570 / 150 251 (145 504 to 182 070) |
| entry with `@nospecialize` | plain | 0 / 72 (45 to 84) | 0 / 41 (34 to 55) |
| entry with `@nospecialize` | route | 0 / 112 (82 to 140) | 0 / 69 (48 to 79) |
| fixed ids by hand (lower bound) | plain | 0 / 18 (12 to 43) | 0 / 15 (13 to 49) |
| fixed ids by hand (lower bound) | route | 0 / 23 (16 to 45) | 0 / 24 (18 to 58) |

Per phase after the fixes, wall µs (compile µs in brackets), without the entry: plain: construct 112 132 (111 708), resolve 19 (0); route: construct 143 647
(143 088), resolve 6 672 (6 572). With the entry: plain: entry 4, construct 36, resolve 1; route: entry 12, construct 47, resolve 9; no compile in any phase.

So without the entry `resolve` itself is now nearly free for a new layout (it compiled 223 000 to 308 000 µs before), and what is left is `construct`, the
`CompositeAlgorithm(...)` constructor, which Julia has to specialize again for every set of fresh id types. The entry removes that by renaming the ids first.
