# Wiring rules

The rules for which names a step sees, which one wins when two give the same name, and what is an error.
Code: `src/Context/View/Locations.jl` (reads), `src/GeneratedCode/SubContextView.jl` (writes).
Keep this file in sync when a rule changes.

## Words

| Word | Meaning |
|---|---|
| state | The fields of a namespace (an algorithm or `@state`), kept in the persistent context for the whole run. |
| route | A wire that gives one step one name, read from a source (another namespace's state, a declared local, an input, a captured return). Optional `transform` (read) and `reverse_transform` (write). |
| share | A wire that gives one step *every* state field of another namespace. Both ways unless `directional = true`. |
| scope | The declared locals and captured returns of the plan node a step runs in. |
| injected | Values handed to a view directly. Only `Package` uses this: each algorithm in a package sees what the earlier ones in the package returned. |
| view | What one step sees: a name → where it is stored. |

## What each kind of step sees

| Step | Sees |
|---|---|
| Algorithm (`@StepAlgorithm`) | its own state, its routes, its shares, injected values. Nothing from the scope unless wired: the DSL wires every argument. |
| Call (`y = f(x)` in the DSL) | its routes, its shares, the scope (declared locals and captured returns, by name), injected values. A call has no state. |

## Which name wins

Lower rows hide higher rows when two give the same name.

| Rank | Kind | Clash with a lower-ranked kind |
|---|---|---|
| 1 (lowest) | scope (calls only) | hidden silently |
| 2 | shares | error with state, error with routes |
| 3 | state | hidden by a route (allowed, see below) |
| 4 | routes | wins over state |
| 5 (highest) | injected | wins over everything |

Inside the scope: a declared local hides a captured return of the same name, and an inner plan node's names hide an
outer one's.

**Why a route may hide state:** it lets you wire an algorithm's own state away, i.e. change which buffer it reads and
writes without changing the algorithm.

## Errors

| When | Error |
|---|---|
| A share and a state field give a view the same name | `` `ns` (Algo) gets `x` both from its state and from its shares `` |
| A share and a route give a view the same name | same message, "routes" and "shares" |
| A step reads a name its view doesn't see | `Variable x requested from ... but not supplied to context. Available names are: ...` |
| A step writes back a name it reads from the inputs | `... reads from _inputs: that is read-only` |
| A step writes back a name it reads through a route with `transform` but no `reverse_transform` (or a route from several variables) | `... has no reverse_transform` |
| A route with a transform maps more than one variable | construction error |

Clash errors are thrown when the step's view is first compiled (the first run), not when the plan is built. Separately,
the DSL rejects `local x` when the block already has an `x` (a state field, an input or an earlier statement's result).

## Writes

What a step returns is written to where its view says the name lives:

| Name lives in | Written to |
|---|---|
| state (own, or through a route or share) | that state field, through `reverse_transform` if the route has one |
| declared locals, captured returns | that runtime slot |
| its own subcontext returns | that slot |
| inputs | error, read-only |
| nowhere in the view | its own subcontext returns if something reads it later, otherwise dropped |

## Not checked (currently silent)

- Two routes into one view with the same name: the later route wins.
- Two shares that both have a field with the same name: the later share wins.
- A route and a scope name clash in a call's view: the route wins.

## Open questions

- Should a call see the scope only through wires, like an algorithm? Then a call's view has only explicit names, and
  any clash in it is an error.
- Routes with an explicit direction (read from, write to); see `TODO.md`.
- Should shares go; see `TODO.md`.
