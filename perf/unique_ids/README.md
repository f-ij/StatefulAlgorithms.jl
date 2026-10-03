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
