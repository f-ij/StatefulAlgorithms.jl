# [Migrating to returns and updates](@id migrating_dsl_user)

How to update code written for the older DSL. In short: what a step **returns** is now a value, as in a Julia
function, and what it **writes back** is marked with `@update`. The rules of a block now follow a Julia loop body more
closely: an assignment runs where it is written, and a name lasts one step unless it is declared with `local`.

If you cannot update everything at once, rename the macros (see [Keeping the old behaviour](#Keeping-the-old-behaviour))
and move one definition at a time.

## 1. `@StepAlgorithm`: write back with `@update`, return values

A `@StepAlgorithm` no longer updates a name by returning it. A step's return is a normal Julia return value: a returned
named tuple is one value, which the block may destructure like any named tuple (`(; a, b) = Algo()` by name,
`a, b = Algo()` by position). A return never writes state; only `@update` does.

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

Hand-written `init(algo, context)` / `step!(algo, context)` methods are **deprecated**: define the algorithm with
`@StepAlgorithm` (`@managed(...)` state, `@update`, `return`). Until they are removed they keep working: a returned
named tuple writes every name back where it lives and is also the step's value, and
`StepResult(value, StateUpdates(; x))` returns a value and writes back separately.

```julia
# Deprecated
struct Counter <: ProcessAlgorithm end
StatefulAlgorithms.init(::Counter, context) = (; count = 0)
StatefulAlgorithms.step!(::Counter, context) = (; count = context.count + 1)

# Instead
@StepAlgorithm function Counter(@managed(count = 0))
    @update count += 1
end
```

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
| `x = 0.0` (a value kept between steps) | `@state x = 0.0`; `x = 0.0` alone assigns 0.0 every step |
| `x = nothing` (no value until written) | `local x`: kept between steps; reading it before its first assignment is an error |
| `x::Float32 = 1` | `@state x = 1.0f0` to keep it; `x::Float32 = 1` alone is `x = convert(Float32, 1)` every step |
| `buf = [0.0, 0.0]` (one buffer) | `@state buf = [0.0, 0.0]`; `buf = [0.0, 0.0]` is a new array every step |
| `local x = v`, `local x = f()` | an error: a declaration has no value. `local x`, then `x = f()`; or `@state x = v` |
| `y = @every 3 f()` (`y` not declared) | an error: `local y` first, since the statement does not run every step |

## 4. Updates of the block's values

An algorithm that updates an argument changes whatever the block passed as that argument:

- a state field: changed, as before;
- a captured return or a `local`: changed too, and building the block warns. If that is intended, declare the name
  with `@mutable` (`@mutable y = produce()`, `@mutable local x`); it changes nothing else.
- an `@input`, an outside value, or a value read through `@transform`: an error when the block is built.

`updated_names(Algo)` lists what an algorithm updates.

## 5. Repeated statements and nested plans have no return value

| Before | After |
|---|---|
| `x = @repeat n Algo()` (`x` the last repeat's return) | an error when the block is built. `@repeat n Algo()` without `x =`; or `local x`, then `@repeat n begin x = Algo() end` |
| `x = @repeat n f(x)` (`x` a state field, updated `n` times) | `@repeat n begin x = f(x) end` |
| `x = nested()`, `nested` a `@CompositeAlgorithm` / `@Routine` | an error when the block is built: a plan has no return value. `local x` before it, and assign `x` inside the plan; or read the plan's state, `@context c = nested()` and `c.field` |
| `x = @repeat n begin … end` | an error when the block is built: `local x`, then `@repeat n begin … x = … end` |

Plain `@repeat n Algo()` and `nested()` are unchanged.

## 6. New, optional

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
