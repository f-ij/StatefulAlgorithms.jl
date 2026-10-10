# DSL semantics

What a `@CompositeAlgorithm` / `@Routine` block means: what each statement does when the block is built and in every
step, where each name lives, how long it lives, and what is an error. The model is a Julia loop body: a block is
the body of a loop that runs once per step, its statements run top to bottom, and names follow Julia's scoping.
`@StepAlgorithm` is covered where it meets the block: what an algorithm reads and what its returns do.

The how-to with more examples is [Composite DSL](@ref composite_dsl_user). This page is the reference: where the two
disagree, this one describes what the code does (branch `refactor/dsl-locals`).

## Terms

| Term | Meaning |
|---|---|
| block | The body of one `@CompositeAlgorithm`, `@Routine` or `@repeat n begin … end`. It becomes one plan node (`CompositeAlgorithm` / `Routine`). |
| statement | One line of a block. Each is a *declaration* (it names something; nothing runs per step), a *step* (it runs in the steps its schedule picks), or *wiring* (it connects names; nothing runs). |
| step | One run of a block's statements, top to bottom. The root block runs one step per loop iteration; a nested block runs as often as its parent schedules it. |
| build | Evaluating the macro's output: `algo = @CompositeAlgorithm begin … end`. Values written in the block that are not block names are taken then. Separate from `resolve`, `init` and `run`. |
| run | One `run(process)`: init, then the steps until the lifetime ends or the process is paused. |
| scope | The names a block's statements see: its own and those of the blocks around it (see [Scopes](#Scopes)). |
| outside value | A name or expression in a statement that is not a block name: a Julia variable, constant or expression from where the macro is written. It is evaluated once, at build. |

## What a block is

A block builds a plan (`CompositeAlgorithm` or `Routine`) that holds, apart from each other:

| Part | Accessor | Comes from |
|---|---|---|
| children | `getalgos` | algorithm calls, function calls, nested blocks |
| schedule | `intervals` / `repeats` | `@interval`, `@every`, `@repeat` (default 1) |
| wiring (routes, shares, declared locals) | `getwiring`, `get_routes`, `get_shares` | arguments of calls, `@route`, `@all`, outputs written to `@state`, `@bind`, `local` |
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

## Name lookup in a step's view

When an algorithm reads `x`, its view takes the first of these that has it:

1. injected values,
2. routes (the block's and inherited plan-wide ones),
3. its own state (the namespace's fields),
4. shares (a share with the same name as a state field or a route is an error),
5. the scope: declared locals and captured returns, inner block before outer.

A route therefore wins over a field of the same name the algorithm stores itself. That is what lets `@bind` target an
algorithm's own field.

## Kinds of names

Every bare name a statement reads is one of these. The kind decides where the value lives and how long.

| Kind | Made by | Lives | On pause | Where |
|---|---|---|---|---|
| state field | `@state x = v`, `@state x`; an algorithm's `init` (its `@managed` fields) | persistent: the process | kept, and saved | stored context, under the block's `_state` or the algorithm's namespace |
| input | `@input x`, `@input x::T`, `@input x = v` | the run, read-only | kept | runtime context, `_inputs` |
| declared local | `local x`, `local x::T`, `local x = v`, `local x::T = v` | the run | kept | runtime context, `_declared_locals` |
| captured return | `y = f(…)` or `y = Algo(…)`: what a call or an algorithm returns, and `x = v` | one step of its block | dropped | runtime context, `_captured_returns` |
| alias | `@alias a = Algo(…)` | build only | – | macro time: `a` names the algorithm in later statements |
| context alias | `@context c = nested()` | build only | – | macro time: `c.sub.field` names fields of a nested plan |

A name is made once per block: declaring a name the block already has is an error (see [Errors](#Errors-when-the-block-is-built)).

## Scopes

Every block is a scope, as a `for` loop body is in Julia.

- A statement sees the names of its block and of every block around it. A name in an inner block hides the same name
  of an outer one.
- Assigning a name that is already visible writes that name: `x = f(x)` in an inner block updates the outer `x`
  (a declared local or a captured return of the outer block), as an assignment in a loop body updates a variable of
  the enclosing function.
- A captured return is unset each time its block is entered: it exists only from its assignment to the end of that
  step of the block. An outer block does not see the returns of an inner block.
- Declared locals keep their value from step to step and across a pause.

A nested block made with `@repeat n begin … end` is its own block. A plan written elsewhere and used in a block
(`nested()`, `@context c = nested()`) is a block of its own as well; it sees only its own names, its inputs and what
is wired to it (`@bind`, `@merge`, `@route`, `c.sub.field`).

A nested `CompositeAlgorithm` without options (no `Local`, routes or shares of its own) is flattened into its
parent when the parent is built, so it shares the parent's scope. That does not change what valid blocks compute:
its returns are reset on the same steps its readers run.

## Statements

### Declarations

| Statement | Meaning |
|---|---|
| `@state x = v` / `@state x` / `@state name begin … end` | A state field of the block (key `_state_1`, `_state_2`, ... per construction, or `name`). With a value, `v` is evaluated at each `init`; without one, `init` must supply it. |
| `@input x` / `@input x::T` / `@input x = v` | A per-run input, given as a keyword to `run`, checked before the loop starts. Assigning it is an error. |
| `@CompositeAlgorithm name(a, b::T = v) begin … end` | A header: assigns the plan to `name`, and each argument is an `@input` of the block (`a`, `b::T = v`). Keyword arguments too. |
| `local x` | A declared local without a value: its type is the type of what is first assigned to it (decided before the run). Reading it before that is an `UndefRefError`. |
| `local x::T` | A declared local of type `T` without a value. |
| `local x = v` | A declared local starting at `v`, a literal or an outside name taken at build. |
| `local x = f(…)` | A declared local, and the step `x = f(…)`: assigned every time the statement runs, as in a Julia loop body. |
| `local x = nothing` | A declared local that reads `nothing` until something is assigned to it. |
| `local x::T = v` | A declared local of type `T` starting at `convert(T, v)`. |
| `@alias a = Algo(…)` | Names an algorithm for later statements: `a(…)` runs it, `a.field` reads its field. |
| `(; a, b) = @state(X)` | From here on, `a` and `b` name the fields `a`, `b` of `X`'s state (`X` an alias or an algorithm of the block). `@state(X).a` reads one inline. |
| `@mutable y = …`, `@mutable local x …` | The statement, and: an algorithm may update `y` (see [What a step's returns do](#What-a-step's-returns-do)). Changes nothing else; it silences the warning. |
| `@context c = nested()` | Runs `nested()` like any statement, and names it so later statements can write `c.sub.field`. |

A declared local's starting value is taken from the plan at the start of every run. Starting values are literals
or outside names, so nothing the block creates is shared between runs; a value kept from the start of the run belongs
in `@state`.

### Steps

| Statement | Meaning, every step it runs |
|---|---|
| `f(a, b; k = c)` | Calls `f`. `f` is a function, so this is a call: a `Callable` in the plan, with no state and no identity. |
| `y = f(…)`, `a, b = f(…)` | Calls `f` and captures its return as `y` (or unpacks a tuple into `a`, `b`). |
| `x = 0.0`, `x = "s"`, `x = (1, 2)`, `x = [0, 0]` | Assigns `x` that value, as in a Julia loop body: the same as `x = f(…)`, a value for one step (or a write, if `x` is a state field or a declared local). A literal is the call `identity(0.0)`; an array literal is a call too (`Base.vect(0, 0)`), so a new array every step. |
| `x::T = v` | `x = convert(T, v)`. |
| `Algo`, `Algo()`, `a()`, `Algo(args…)` | Runs the algorithm's `step!`. `Algo` is an algorithm type or value, or an alias. |
| `y = Algo(…)`, `a, b = Algo(…)`, `(; a, b) = Algo(…)` | Runs the algorithm and captures its return value as for a call: the whole value, a tuple unpacked, or its properties `a`, `b` (see [What a step's returns do](#What-a-step's-returns-do)). |
| `x = f(…)` with `x` a state field | Calls `f` and writes the return into the state field `x`. |
| `x = v` with `x` a state field, `v` an outside value | Writes `v` (taken at build) into the state field every step (`ContextWrite`). |
| `owner.field = f(…)` | Calls `f` every step and writes the return into the algorithm's or nested plan's field. |
| `buf[i] = v`, `buf .= v`, `buf[i] .= v` | Mutates the state buffer in place (`setindex!`, broadcast through a view). |
| `nested()`, `c = nested()` | Runs the nested plan's step. |

Which name a statement's arguments read:

- A bare name that is a block name (a state field, input, declared local or captured return, in this block or a block
  around it) reads that value in the step.
- `a.field` / `c.sub.field` reads a field of an aliased algorithm or a nested plan's state.
- `@transform(f, name)` reads `name` and passes `f(name)`. `x[]`, `x[i]`, `x[2:3]` read `x` and index it.
- Anything else is an outside value, evaluated once at build: `f(somevar)`, `f(1.5)`, but also `f((a, b))` and
  `f(a + 1)`. An expression is not a step computed from block names; write a call for that (`f(g(a, b))` is two
  statements: `t = g(a, b)`, `f(t)`).
- For an algorithm, keyword arguments are wires: `Sink(value = produced)` gives `Sink` the name `value` reading
  `produced`. An algorithm defined with `@StepAlgorithm` also takes its positional arguments by position.
- Wires belong to the statement: the same algorithm at two positions (`AddOne!(y)`, `AddOne!(x)`) is one algorithm
  with one state, and each position reads and updates its own arguments.

### Schedules

| Form | Meaning |
|---|---|
| (none) | In a composite, every step; in a routine, once per step. |
| `y = @every n f(…)` / `@interval n` | In a composite: runs in the steps whose number is a multiple of `n`. |
| `y = @repeat n f(…)` | In a routine: runs `n` times in a row. Also `@repeat Until(cond, x) …` and the other lifetimes. |
| `@repeat n begin … end` | A nested block, run `n` times in a row each time the parent runs it. |

The schedule goes on the right-hand side: `@every 3 y = f()` is an error.

### Wiring

Nothing runs; these decide where values go.

| Statement | Meaning |
|---|---|
| `@route a.x => b.y` (`transform = f`, `reverse_transform = g`) | `b` sees `a`'s `x` as `y`; returning `y` writes back through `g`. |
| `@replace a.x => b.y` | `b`'s field `y` is `a`'s field `x` after init. |
| `@bind x => c.x` | This block's state field `x` and the nested block's `x` are the same field. |
| `@merge c1.x, c2.x` | Two nested blocks' fields `x` are the same field. |
| `Algo(@all(a))` | `Algo` sees every field of `a` (a `Share`). |

### When the block is built

| Statement | Meaning |
|---|---|
| `@include_if cond stmt` / `@include_if cond begin … end` | `cond` is evaluated at build; when false, the statements are left out entirely. |
| `@finally f` | Root block only: after the last step, `f(context)` gives the run's result. It reads the root block's captured returns of the last step. |

## What a step's returns do

A step returns a value, as a Julia function does, and separately writes back its updates.

- **The value.** `y = f(x)` and `y = Algo(x)` capture it into the block's scope under the names on the left of `=`
  (`a, b = …` unpacks a tuple, `(; a, b) = …` takes properties). Names nothing reads are dropped. For an algorithm,
  the plan keeps its return for one step (under `_return` in its namespace's subcontext returns) and a call of
  `identity` right after it, on the same schedule, captures it; a name on the left that is a state field of the block
  is written there, one that is a declared local writes the local.
- **The updates.** A `@StepAlgorithm` writes back exactly what its body marks with `@update x` (`updated_names` lists
  them): `x`'s value at the `return` goes to where the algorithm read `x` from, its own `@managed` state or the
  variable of the block passed as `x` (through the wire of that argument, or a share). A hand-written `step!` returns
  `StepResult(value, StateUpdates(; x))` for the same, or a plain named tuple, which keeps the older meaning: every
  returned name is written back where it lives, and the named tuple is also its value.

Which values of the block an update may change:

| Passed as the updated argument | What happens |
|---|---|
| a state field (the block's, or `a.field`) | changed: state is mutable memory |
| a captured return or a declared local | changed, and building the block warns, unless the name was declared `@mutable` |
| an `@input` or an outside value | error when the block is built |
| a value read through `@transform` | error when the block is built |

## Errors when the block is built

- Declaring a name the block already has (`@state x` then `local x`).
- Assigning an `@input`.
- `x = y` with `y` a block name: a bare name is not a step. Copy it with a call, `x = copy(y)`.
- A captured return read in a step where it was not assigned: `y = @every 3 f()` read by a statement that runs every
  step. Declare `y` (`local y`, `local y = nothing`) to keep it between steps.
- `local x` inside `@include_if` or `@context`.
- A schedule on the left (`@every 3 y = f()`), `@finally` in a nested block, a route that reads a local or return
  no block declares or captures.
- An algorithm that updates an argument given an `@input`, an outside value or a `@transform` (see above).
- `y = @state(X)`: take fields by name, `(; a, b) = @state(X)`.

## Known gaps

- The how-to's "Direct State Writes" shows `target = source` with two state fields. That never worked (it read
  `source` as an outside value); it is now the `x = y` error. Write `target = copy(source)`.

## Open

**Unread captures.** A capture whose names nothing reads still makes the algorithm keep its return for the step
(the `_return` slot). It costs no time per step that could be measured; pruning such captures when the block is built
would remove the slot.
