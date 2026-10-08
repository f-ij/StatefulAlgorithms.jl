# DSL Semantics Map

What each statement of a `@CompositeAlgorithm` / `@Routine` block becomes, what it changes, and how far its effect
reaches. The user-facing description with examples is in [Composite DSL](@ref).

## What a block is

A block builds a plan (`CompositeAlgorithm` or `Routine`) that holds, apart from each other:

| Part | Accessor | Comes from |
|---|---|---|
| children | `getalgos` | algorithm calls, function calls, nested blocks |
| schedule | `intervals` / `repeats` | `@interval`, `@every`, `@repeat` (default 1) |
| wiring (routes and shares) | `getwiring`, `get_routes`, `get_shares` | arguments of calls, `@route`, `@all`, outputs written to `@state`, `@bind` |
| states | `getstates` | `@state`, `@input` |
| options | `getoptions` | `@replace`, `@input` (`RuntimeInputs`) |

`resolve` wraps the plan in a `LoopAlgorithm`: it names every algorithm and state in a registry, resolves the wiring
against it, and collects the `RootOption`s (`Replace`, `RuntimeInputs`) of every plan in the tree. `states(la)` lists the
states of the resolved tree by name.

## Identity

| Thing | Matched by | Name in the context |
|---|---|---|
| an algorithm value | its value (`===` for mutable values, equality for values without data) | `Type_1`, `Type_2`, ... or its `@alias` |
| a block's `@state` | an id given when the block is built: one per construction | `_state_1`, `_state_2`, ... |
| a named state (`@state name begin ... end`) | its name: every state with that name is one | `name` |
| a merged state (`@merge`) | the id of each state it was merged from | `_state_k` |

The same block value used in two places shares its state; two constructions, also from the same code, do not.

## Statements

| Statement | Becomes | Changes | Effect reaches |
|---|---|---|---|
| `@state x = v`, `@state x` | a field of the block's `@state` (`GeneralState`); `v` is evaluated at each init, no default means required at init | storage | the block |
| `@state name begin ... end` | a state keyed `name` | storage | everything named `name` |
| `@input x` | a runtime input of the run | inputs | the run |
| `@alias a = expr` | a name for `expr` in later statements; no runtime value | nothing | later statements |
| `@context c = block()` | a name for the nested block, for `c.x` references | nothing | later statements |
| `Algo(x = y)`, `a(x = y)`, `y = a()` | a child, with a route per argument and outputs available to later statements | children, wiring | the block |
| `y = f(x)` (a Julia function) | a `FuncWrapper` child with routes from `x` | children, wiring | the block |
| `x = f(x)` with `x` a `@state` field | the call's output written back to the state through its route | wiring | the block |
| `a.x = f(...)`, `x = value`, `x[i] = v`, `x .= v` | a write into the field (`ContextWrite` or a call) | children, wiring | the block |
| `@route a.x => b.y` | a plan-wide `Route` | wiring | the block and every plan below it |
| `@transform(f, x)` as an argument | a route with a transform | wiring | the block |
| `@all(a)` as an argument | a `Share`: the target sees all fields of `a` | wiring | the block |
| `@bind s => t ...` | the routes that read `t` read `s`; `t`'s block state drops the field; an algorithm `t` gets a route from `s` | wiring | the block, or its `begin ... end` |
| `@merge c1, c2` | one state matched by the ids of both blocks' states | identity | everywhere |
| `@replace a.x => b.y` | a `Replace` option: after init, `b.y` is stored in `a.x` | storage | the whole run |
| `@interval n` / `@every n` / `@repeat n` (or a lifetime) | the schedule of that entry | schedule | the entry |
| `@repeat n begin ... end` | a nested plan with its own scope | children | the block |
| `@include_if cond stmt` | `stmt`, or nothing when `cond` is false at construction | children, wiring | the block |
| `@finally f` | `f(context)` after the run; root block only | result | the run |

## Name lookup in a step's view

When an algorithm reads `x`, its view looks in this order and takes the first that has it:

1. injected values,
2. routes (the block's and inherited plan-wide ones),
3. its own state (the namespace's fields),
4. shares.

A route therefore wins over a field of the same name the algorithm stores itself. That is what lets `@bind` target an
algorithm's own field.
