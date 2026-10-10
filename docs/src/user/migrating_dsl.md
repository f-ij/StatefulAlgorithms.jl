# [Migrating to returns and updates](@id migrating_dsl_user)

How to update code written for the older DSL. In short: what a step **returns** is now a value, as in a Julia
function, and what it **writes back** is marked with `@update`. The rules of a block now follow a Julia loop body more
closely: an assignment runs where it is written, and a name lasts one step unless it is declared with `local`.

If you cannot update everything at once, rename the macros (see [Keeping the old behaviour](#Keeping-the-old-behaviour))
and move one definition at a time.

## 1. `@StepAlgorithm`: write back with `@update`, return values

A `@StepAlgorithm` no longer updates a name by returning it. A returned named tuple is the step's return value.

| Before | After |
|---|---|
| `return (; x = x + 1)` (to update `x`) | `@update x = x + 1` |
| `count += 1; return (; count, E = f(count))` | `@update count += 1; return (; E = f(count))` |
| `return (; total)` (to update `total`) | `@update total`, then `return` (or end the body with the `@update`) |
| `return (; E, M)` (values for the block) | unchanged; the block takes them with `(; E, M) = Algo()` (see 2) |

- `@update x` writes `x`'s value at the `return` back to where the algorithm read it from: its `@managed` state, or
  the variable of the block passed as `x`. `@update x = v`, `@update x += v` and `@update x, y` are short forms.
- Only an argument can be updated (positional, `@managed`, keyword).
- A body that ends in `@update …` returns `nothing`; no `return` is needed.
- Called directly, `step!(Algo(), args...)` returns the value.
- The macro warns when a body returns a named tuple with a name that is also an argument
  (``"`Algo` returns `x`, which is also an argument"``): that is almost always an update written the old way.

A hand-written `step!(algo, context)` needs no change: a returned named tuple still writes every name back where it
lives, and it is also the step's value. To return a value and write back separately, return
`StepResult(value, StateUpdates(; x))`.

## 2. Taking what an algorithm returns

`y = Algo()` now captures the whole return value, as `y = f()` does for a function.

| Before (binds returned fields by name) | After |
|---|---|
| `y = Algo()` where `Algo` returns `(; y, …)` | `(; y) = Algo()` |
| `a, b = Algo()` where `Algo` returns `(; a, b)` | `(; a, b) = Algo()` (`a, b = Algo()` now unpacks positionally) |
| `x = Algo()` with `x` a `@state` field | unchanged in form; `x` now gets `Algo`'s return value |
| `a.y` reading another algorithm's returned `y` | capture it where it runs (`(; y) = a()`) and read `y` |

The names on the left are values of the block for that step, like the result of a call, and nested
`@repeat … begin … end` blocks see them.

To read an algorithm's **state** by name, `a.field` still works for an alias; for any algorithm of the block:

```julia
Counter()
(; count) = @state(Counter)     # `count` is Counter's state field from here on
Report(@state(Counter).count)   # inline
```

## 3. Assignments run where they are written

| Before | After |
|---|---|
| `x = 0.0` (a local kept between steps) | `local x = 0.0`; `x = 0.0` alone assigns 0.0 every step |
| `x = nothing` (`nothing` until written) | `local x = nothing` |
| `x::Float32 = 1` | `local x::Float32 = 1` to keep it; `x::Float32 = 1` alone is `x = convert(Float32, 1)` every step |
| `buf = [0.0, 0.0]` (one buffer) | `@state buf = [0.0, 0.0]`; `buf = [0.0, 0.0]` is a new array every step |
| `local buf = zeros(3)` (one buffer) | `@state buf = zeros(3)`; `local buf = zeros(3)` assigns a new array every step |

## 4. Updates of the block's values

An algorithm that updates an argument changes whatever the block passed as that argument:

- a state field: changed, as before;
- a captured return or a `local`: changed too, and building the block warns. If that is intended, declare the name
  with `@mutable` (`@mutable y = produce()`, `@mutable local x = 0.0`); it changes nothing else.
- an `@input`, an outside value, or a value read through `@transform`: an error when the block is built.

`updated_names(Algo)` lists what an algorithm updates.

## 5. New, optional

- `@CompositeAlgorithm mc(spins, n = 3) begin … end` assigns the plan to `mc` and declares `@input spins` and
  `@input n = 3`.

## Keeping the old behaviour

The old rules are kept for now under new names, in `src/Legacy`:

| Macro | Legacy name |
|---|---|
| `@CompositeAlgorithm` | `@CompositeAlgorithm_legacy` |
| `@Routine` | `@Routine_legacy` |
| `@StepAlgorithm` | `@StepAlgorithm_legacy` |

They warn once that they are deprecated, and will be removed. They differ only in sections 1 and 2: `y = Algo()`
binds the returned field `y`, and a `@StepAlgorithm_legacy` updates a name by returning it. The rest of this page
(assignments, `local`, nested blocks) applies to them too. Use legacy algorithms in legacy blocks: in a
`@CompositeAlgorithm_legacy` block, `y = Algo()` with a new `@StepAlgorithm` does not find a returned field `y`.

A migration in steps: rename every macro to its legacy name; then move one `@StepAlgorithm` at a time (section 1),
then the blocks that use it (sections 2 to 4), and drop the `_legacy`.
