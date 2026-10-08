# Migrating: State Sharing and Plans

How to rewrite code for the change that gives every block its own state. Each row is the old form, what it did, and
what to write now.

## State sharing

| Old code | What it did | Now |
|---|---|---|
| two nested blocks both declaring `@state buffers`, nothing else | one `buffers` shared by both, with an overlap warning | two separate `buffers`. To share them: `@merge f, n` (the whole states) or `@bind buffers => f.buffers` in the parent |
| `@bind buffers => f.buffers` | silenced the overlap warning; the sharing came from the equal names | the same line: `f.buffers` is the parent's `buffers` inside the parent. The names may now differ: `@bind log => f.buffers` |
| `@merge f.buffers, n.buffers` | silenced the overlap warning | `@merge f, n` merges the whole states. For one field: `@bind buffers => f.buffers` and `@bind buffers => n.buffers` with a `@state buffers` in the parent, or `@replace` |
| `@merge f._state.buffers, n.buffers` | as above | as above |
| `ctx[:_state]`, `context(p)[:_state]` | the one merged block state | `ctx[:_state_1]` (the first block state), or look it up: `keys(states(resolve(algo)))` |
| `Init(:_state; x = ...)` | init input for the merged block state | `Init(:_state_1; x = ...)`, or the name from `states(resolved)` |
| `algo._state` | the block's state | `getstates(algo)` (the block's own states); in the DSL `c.x` still works |
| `@replace` only in the outer block | was collected from the root wrapper | allowed in any block; collected from every plan |

## Types and accessors

| Old | Now |
|---|---|
| `ProcessState`, `@ProcessState` | `AlgoState`, `@AlgoState` |
| an unresolved block with `@state` is a `LoopAlgorithm` | it is its plan (`CompositeAlgorithm` / `Routine`); only `resolve` makes a `LoopAlgorithm` |
| `getstates(la)` reads the wrapper | reads the plan; `states(la)` gives every state of a resolved tree by name |
| `getoptions(plan)` returns routes and shares | returns the plan's other options (`Replace`, `RuntimeInputs`); routes and shares: `get_routes`, `get_shares`, `getwiring` |
| `getoptions(plan, Route)` | `get_routes(plan)` |
| `setoptions(plan, routes)` set the wiring | `setwiring(plan, routes)`; `setoptions(plan, options)` sets the other options |
| a route to a name the target also stores was ignored | the route wins |
