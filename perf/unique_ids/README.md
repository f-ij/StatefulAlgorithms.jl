# Unique() ids: stop recompiling when the same code runs again

Every call of `Unique(f)` draws a random UUID that becomes a type parameter, so each call makes a new type and everything specialized on
it is compiled again: constructing the plan, resolving it, and the loop. Re-running the same user code costs 420 to 600 ms per call
instead of 0.1 to 0.2 ms (measured; the cost is compile time, not a per-iteration cost).

Idea (prototyped here at user level, no package changes): put a type-erased entry in front of the constructor that renames the random
ids to `SimpleId(1..N)` in order of first appearance and then calls the normal constructor dynamically. Everything behind the entry only
ever sees the sequential ids, so it is compiled once. The registry and the loop do not change.

```bash
julia --project=perf/unique_ids -e 'using Pkg; Pkg.instantiate()'
julia --project=perf/unique_ids perf/unique_ids/proto_normalize.jl   # unnamed duplicates: wall time per call
julia --project=perf/unique_ids perf/unique_ids/proto_typed.jl       # type-stable vs type-erased normalizer, compile time
julia --project=perf/unique_ids perf/unique_ids/proto_routes.jl      # a held handle used in a Route
```

## Results

Two `Unique(Counter())` and a `Tally` in a `CompositeAlgorithm`, constructed, resolved, initialized and run for 1000 iterations,
re-executed. "compile" is Julia's cumulative compile-time counter for the whole call.

| case | today (random ids), ms | through the normalizing entry, ms |
|---|---|---|
| unnamed duplicates, wall time per call (calls 2 to 5) | 422 to 445 | 0.1 to 0.2 |
| unnamed duplicates, compile time per call | 427 to 480 | 0.00 (type-erased entry) |
| unnamed duplicates, compile time per call | 427 to 480 | 11 (type-stable generated entry) |
| two duplicates and a `Route` from a held handle, compile time per call | 567 to 583 | 6.6 to 7.5 |

* The normalizing function must not specialize on the fresh types: keying a dictionary on the `SimpleId` instance made `hash` and `==`
  specialize on it and cost 24 ms per call; keying on the UUID value pulled out of the type parameter costs nothing.
* A type-stable (generated) normalizer works but still compiles about 11 ms per fresh call, because it specializes on the fresh types.
  The shape that costs nothing is an erased boundary that dispatches dynamically into the type-stable core, which is compiled once.
* The remaining 7 ms with a `Route` is the user-facing `Route(b => Reader, :x)` constructor, which sees the fresh handle type before the entry
  runs. The constructors that take handles (`Route`, `Share`, `Replace`, `Init`, `Override`) would need the same treatment (an erased front end
  that builds an untyped description which the entry turns into the typed object after renaming).
* Not prototyped: looking up a held handle after construction (`la[b]`, `Init(b)` in `partialinit`). The plan would keep a plain table from
  uuid to ordinal (data, not type) so a held handle is renamed at that entry too; the core keeps matching statically on `SimpleId(n)`.

## Full measurement (measure_ids.jl, one fresh Julia process per approach and layout)

`julia --project=perf/unique_ids perf/unique_ids/measure_ids.jl <today|erased|erased_route|typed|fixed> <plain|route>`.
Compile milliseconds (Julia's compile-time counter; wall time is within 0.2 ms of it). "first run" is a cold compile; "same handles again"
reuses the handles three times; "new uuids" builds fresh `Unique`s in the same positions four times (min to max over the four). Raw lines
are in `results_compile_ms.txt`.

| approach | layout | first run | same handles again, max of 3 | new uuids, same layout |
|---|---|---|---|---|
| today (random ids) | plain duplicates | 837 | 0.0 | 436 to 535 |
| today | held handle in a `Route` | 1049 | 0.0 | 534 to 624 |
| erased entry | plain | 772 | 0.0 | 0.0 |
| erased entry, normal `Route` | route | 1046 | 0.0 | 7.9 to 11.6 |
| erased entry + erased `Route` front end | plain | 772 | 0.0 | 0.0 |
| erased entry + erased `Route` front end | route | 1055 | 0.0 | 0.0 |
| type-stable (generated) entry | plain | 820 | 0.0 | 4.9 to 8.1 |
| fixed ids by hand (lower bound) | plain / route | 829 / 963 | 0.0 | 0.0 |

The harness stores the handles in a `Vector{Any}` and marks `build` as non-specializing: passing fresh-typed handles through specialized functions
(or a `Tuple` of them) makes those functions compile per call (about 32 ms, then 3.7 ms, in two earlier versions). User code that passes handles to
helper functions specializes the same way, whatever the entry does; only handles of a fixed type avoid that.

## Type stability today (resolve_infer.jl, infer_check.jl)

On a concrete normalized plan: `LoopAlgorithm(plan)`, `attach_registry_to_tree` and `init` infer to concrete types;
`setup_registry_and_keyed_algos` returns `Tuple{NameSpaceRegistry, Any}` (the keyed plan type is lost in `add_algos_to_registry`) and
`resolve_plan_wiring` returns `Any`, so `resolve` is `Any` independent of the ids. The erased entry also returns `Any`; the generated (type-stable) entry
infers it at 4.9 to 8.1 ms per fresh-uuid call.

## In microseconds, and what the `@nospecialize` marker is worth (measure_us.jl, count_specs.jl)

What the "entry" is: a small function in front of `CompositeAlgorithm` that receives the handles as untyped values, renames the random ids to
1, 2, ... in order of appearance, and calls the normal constructor with the renamed handles (which Julia has already compiled). `@nospecialize`
tells Julia not to compile a separate version of that function for every argument type; the random-id types are different every call, so without
the marker the entry itself is recompiled every call.

Cost of one call after the first one, building fresh `Unique`s in the same positions, microseconds (median; min to max in brackets). "compile"
is Julia's compile-time counter, "wall" is the whole call: construct the plan, resolve, init, run 1000 iterations.

| version | layout | compile, microseconds | wall, microseconds |
|---|---|---|---|
| today (random ids, no entry) | plain / route | 436 000 to 535 000 / 534 000 to 624 000 | same |
| entry with no marker | plain | 10 437 | 10 554 (10 282 to 11 271) |
| entry with no marker | route | 13 275 | 13 464 (12 393 to 38 980) |
| entry with `@nospecialize` | plain | 0 | 13.9 (13.3 to 136) |
| entry with `@nospecialize` | route | 0 | 19.5 (17.4 to 136) |
| entry with `@nospecialize` + `@nospecializeinfer` | plain | 0 | 15.0 (14.0 to 115) |
| entry with `@nospecialize` + `@nospecializeinfer` | route | 0 | 19.0 (18.0 to 137) |
| type-stable generated entry | plain | 3 442 | 3 525 (3 200 to 4 061) |
| fixed ids by hand (lower bound) | plain / route | 0 / 0 | 17.4 (12.4 to 107) / 15.9 (15.1 to 120) |

Reusing the same handles again costs the same in every version: 14 to 20 microseconds wall, 0 compile.

Compiled variants of the entry functions left behind after N fresh-uuid calls (route layout):

| entry version | N = 1 | N = 5 | N = 20 | N = 50 |
|---|---|---|---|---|
| no marker | 8 | 24 | 84 | 204 |
| `@nospecialize` | 3 | 3 | 3 | 3 |
| `@nospecialize` + `@nospecializeinfer` | 3 | 3 | 3 | 3 |

`@nospecializeinfer` made no difference here, because the callers hold the handles as untyped values. It matters only when a caller sees the
concrete types (then plain `@nospecialize` still leaves an inferred-only variant per type); with a 30-type test it was 31 variants against 1.

Phases of one call after compilation (route layout, median of 30), microseconds: create 2 `Unique` handles 4.5; entry, renaming the ids and constructing
the plan 15.0; resolve 2.5; init below the timer's resolution; run, 1000 iterations 0.5.

## Cold and warm, resolve pipeline only (measure_phases.jl)

The resolve pipeline is: the entry (rename the ids, build the untyped `Route` description), construct the plan (`CompositeAlgorithm`), and `resolve`.
`init` and `run` are not part of it: after `resolve` the ids are gone and the key names are deterministic, and even with random ids `init` and
a one-iteration `run` compiled nothing in these runs. "Cold" is the first call in a fresh Julia process (compile counter, microseconds; five
fresh processes, min / median / max). "Warm" is a later call with new `Unique`s in the same positions (median of 8, microseconds; min to max of the wall time).
`plain` is two `Unique` counters and a `Tally`, nothing connected; `route` adds a `Reader` that takes its input from the second counter through a `Route`.
Raw lines: `results_phases_raw.txt` (all phases, cold and warm) and `results_cold_raw.txt` (the five cold samples).

| version | layout | cold, compile µs (min / median / max) | warm, compile µs | warm, wall µs (min to max) |
|---|---|---|---|---|
| today (random ids, no entry) | plain | 385 186 / 439 315 / 460 803 | 290 420 | 291 113 (273 496 to 307 419) |
| today | route | 495 435 / 544 120 / 573 380 | 356 875 | 357 720 (344 552 to 365 002) |
| entry with `@nospecialize` | plain | 462 126 / 519 930 / 575 379 | 0 | 72 (45 to 84) |
| entry with `@nospecialize` | route | 554 410 / 645 719 / 650 601 | 0 | 112 (82 to 140) |
| fixed ids by hand (lower bound) | plain | 384 412 / 401 234 / 445 519 | 0 | 18 (12 to 43) |
| fixed ids by hand (lower bound) | route | 488 901 / 517 971 / 582 394 | 0 | 23 (16 to 45) |

Phases of the warm call with the entry (median, wall µs): plain: entry 7, construct 54, resolve 8; route: entry 19, construct 69, resolve 20.
Phases of the cold call with the entry (one process, compile µs): plain: entry 32 912, construct 234 016, resolve 213 620; route: entry 40 228,
construct 249 646, resolve 289 041. Without the `@nospecialize` annotation the warm entry alone costs 10 079 (plain) and 11 582 (route) µs.

Reading: warm goes from about 290 000 to 357 000 µs down to 72 to 112 µs. Cold gets worse by the entry's own first-time compile, about 33 000 to 40 000 µs
measured in one process, and 80 000 to 100 000 µs between the medians of five processes, whose spread (about 60 000 µs) is larger than the effect.
Most of the cold cost, about 450 000 to 540 000 µs, is compiling `construct` and `resolve` themselves, with or without the entry.
