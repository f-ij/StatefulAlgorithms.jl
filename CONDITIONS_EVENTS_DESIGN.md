# Conditions and events: design decisions

Two ways for a loop algorithm to run something only some of the time:

- a **condition**, checked when a child is scheduled or a repeat starts: "does this hold now?"
- an **event**, checked at each merge into a value: "did this merge change it?"

`OnChange` for state values, with its condition and `AfterMerge`, is built on `feat/on-change`; the rest is not built yet. These are the decisions agreed so far, and what is still open. Locals are designed against
`exp/no-maybe` (a local's type is the join of what its writers return; no `Maybe`).

## 1. Conditions

1.1 `Condition` is the shared field type for "a function plus the `Var`s it reads": `struct Condition{V<:Tuple, F}; cond::F; vars::V; end`, with one hook, `holds(c, context) -> Bool`. The `Var`s stay in a field, not a type parameter (Unique handles keep their id as data).

1.2 `RunIf` becomes `interval` + `condition`. The interval stays a separate, type-level part because `lcm`/unrolling needs it when compiling.

1.3 `Until`, `RepeatOrUntil`, `AtLeast` and `AtLeastAtMost` hold a `condition` field instead of `cond` + `vars`. `lifetime_breakcondition` calls `holds`. `AtLeast*` keeps its `done >= atleast` guard (that reads the repeat count, not the context).

1.4 DSL: plain Julia `if expr … end` / `else` in a block lowers to children scheduled on a `RunIf` with a `Condition`. Assignments inside follow the `@every` rule (the name exists first: `local y`).

1.5 No `Not`/`And`/`Or` types. The DSL folds the whole expression into one generated function (`if x > 0 && !flag` → `Condition((x, flag) -> x > 0 && !flag, Var(x), Var(flag))`); `else` is the same function with `!`.

1.6 No `Once`. "Once at the start" is a child placed before the loop in a routine.

1.7 Conditions that remember something (for example "true every 3rd time `c` holds") are ordinary step algorithms that return a `Bool`, read by the `if`. This is polling, not event handling.

## 2. Events: `OnChange`

### 2.1 What it is

2.1.1 `OnChange` is a **value wrapper**, like `InteractiveVar`. It holds the value and the callback to run.

2.1.2 The wrapper changes the write action itself. Its write method is picked by dispatch when compiling and compiles to one inline runtime check. The old value is the one the wrapper holds, so nothing is copied.

2.1.3 It is written back with its type fixed (`convert(T, new)`), so the context's type doesn't change.

### 2.2 Where the callback comes from

2.2.1 Nobody owns the callback: the value carries it. The statement that defines a value (a `Callable` in its own scope, or a local at its definition) puts an `OnChange` value there, and that value is passed down to whoever writes it.

2.2.2 Writes through it fire the callback. The definition itself does not.

2.2.3 This works for persistent and runtime values alike. For runtime values, the runtime merges (captured returns' `merge`, locals' `_write_locals`) get the same write hook as persistent writes (`write_value`): they ask the stored value what a write does.

2.2.4 Typing (no-maybe): a writer returns a plain `T` while the slot holds `OnChange{T}`. The hook also tells `settle_locals` that a write into `OnChange{T}` stays `OnChange{T}`, so the join doesn't widen to `Union{OnChange{T}, T}`.

### 2.3 When it fires: at every merge

2.3.1 `OnChange` is a between-steps facility. What happens inside a step of an algorithm is opaque: only what the step leaves behind counts. It is a changed flag, not a count of writes.

2.3.2 The boundary is the literal merge: every merge into the value is one check, and fires the callback at most once. No extra scope rule decides it.
- 2.3.2.1 In a routine, `x = @repeat 10 child()` is the repeated block `local x; @repeat 10 begin x = child() end` (`_dsl_repeated_assignment`): 10 merges into `x`, so up to 10 callbacks.
- 2.3.2.2 To merge once, write `@repeat 9 child(); x = child()` (the same 10 runs, the last one assigns).

2.3.3 `OnChange(value, callback, condition = !==)` fires when `condition(old, new)` holds for the held and the merged value; any function of the two works (for example `(old, new) -> new % 3 == 0`). By default it compares them (`old !== new`), which means the same for every type: a different value (for an array: replaced by another object). With `!==`, `NaN` to `NaN` doesn't fire and `0.0` to `-0.0` does; this goes in the docstring. The callback gets `(old, new)`.

### 2.4 `OnMutate`: in-place writes

2.4.1 Writes into the same object (an array changed in place) are a separate wrapper, `OnMutate`, not part of `OnChange`. It differs in meaning (written to, not different), in what the callback gets (`(new)`: the old contents are gone) and in implementation (a forwarding wrapper with a flag). A user picks the one they mean; both work on arrays.

2.4.2 `OnMutate` is a thin wrapper during the step that is not stripped right away. Any mutating operation sets a flag, once per operation.

2.4.3 Bulk operations forward to the inner array and set the flag after, so they lower to exactly the same code on the contained array (for example `copyto!(w::OnMutate, bc::Broadcasted) = (copyto!(parent(w), bc); setflag!(w); w)`, and likewise `fill!`, `mul!`, `map!`).

2.4.4 The flag is checked and reset at the merge of any step that can write the value. A step that mutates it and returns `nothing` still goes through a merge (`merge(scv, ::Nothing)`), so that is where its flag is checked.

### 2.5 Callback after the merge

2.5.1 A new terminating write action, `AfterMerge(f, args)`, runs `f(args...)` *after* the merge it is part of. `OnChange` answers its `DirectWrite` and an `AfterMerge` that checks the condition and runs the callback. Open: `f` gets nothing of the merged context yet.

2.5.2 `_build_write_payload` splits actions by type when compiling: `DirectWrite`s go into the payload, `AfterMerge`s into a second tuple, which `merge(scv, args, demand)` runs after `merge_into_subcontexts`.

2.5.3 A callback is either a plain function (side effects only), or something stepped through a view whose returns go through the normal `merge`. Chains of events are then repeated merge rounds. Their number is known when the plan is built, so the generated code stays flat; cycles are an error when the plan is built.

2.5.4 When several watched fields change in one merge, their callbacks run in field order.

### 2.6 Handlers as mini plans (the DSL form)

2.6.1 Syntax: a `do` block. At the definition, `@state x = OnChange(0.0) do new … end`; for an existing state variable, a top-level `@OnChange x do new … end`. The first lowers to `@state x = 0.0` plus the second, so there is one mechanism.

2.6.2 The `do` body is a small DSL block (a mini plan): statements, calls, algorithms with state, and a `return`. Its names resolve the way a block's names do, so no new scan for free names is needed. Its writes are ordinary merges.

2.6.3 The mini plan is a child of the plan, in the same children tuple, marked by its schedule entry `OnChange(x)` (in `intervals` for a composite, in the lifetimes for a routine). Every walk over the children (registry, keys, `init`/`cleanup`, typing the locals, UniquePlanId, Inspection, `Edit`, `Copy`) sees it as an ordinary child. Not a separate field: that would have to be added to every one of those walks.

2.6.4 Only the code that builds the shape of the step treats it differently: no step at its position. After each sibling that may write `x` (known from the types, as `_find_writable_fields` computes it), the step code steps it when the wrapper's flag is set, and clears the flag. `lcm` over the intervals skips `OnChange` entries.

2.6.5 The wrapper's write only sets the flag: it compares old and new, checks the condition, and merges `OnChange(new, …; fired = true)`. The flag is a `Bool` field of the immutable wrapper, so the context's type stays the same. `new` in the handler is `x` itself (after the merge it holds the new value); `old` needs a `previous` field in the wrapper.

2.6.6 No pausing during a handler, for now. The handler is stepped with a `LoopRunProcess` made on demand and a fresh non-pausable cursor (`loop_cursor(plan, Val(false))`), as the hand-driven `_step!(la, context)` does. `process_breakcondition` is `false` for a `LoopRunProcess`, so a handler always runs to its end; the outer process's pause check comes after.

2.6.7 `AfterMerge` stays for the plain-function form (`OnChange(value, callback, condition)` without the DSL).

### 2.7 Scope

2.7.1 Events within the loop algorithm only. This system is not meant for async compute.

2.7.2 An `OnChange` wrapping an `InteractiveVar` is not supported.

## 3. Considered, not planned: events from interactive writes

3.1 External writes (`interact!`, `ref[] = v` from another task) don't fire `OnChange`.

3.2 Firing on the next write inside the loop doesn't work: it would make strange implicit boundaries that only fire when something else writes the value.

3.3 The considered approach is an `OnRead` action. An external write marks the `InteractiveVar` dirty, and the first read inside the loop after that runs the callback first.
- 3.3.1 No merge during the read: the read answers the value plus write requests, which are added to the reader's write requests and merged with its returns. That keeps one merge per step; a double write of one field is already an error.
- 3.3.2 Only the first read runs it, because that read clears the flag.
- 3.3.3 The flag must be atomic, and the value published before the flag.

## 4. Open

4.1 `OnMutate` (2.4):
- 4.1.1 Hand-written element loops (`x[i] = …` on the wrapper) store the flag every iteration. Check whether LLVM moves it out of the loop.
- 4.1.2 `getindex`/`setindex!` on the wrapper must be `@propagate_inbounds`.
- 4.1.3 Aliasing: a reference held elsewhere (in an algorithm's own state since `init`, or shared into another subcontext) writes past the wrapper. Rule: a watched array is written only through its watched name. Shares can be detected when the plan is built.

4.2 Callback writes (2.5.3):
- 4.2.1 The action types are fixed when compiling, so an extra write happens every step. When nothing changed, it writes back the value already there; the callback's result converts to that location's type.
- 4.2.2 How a wrapper's target `Var` becomes a location type when compiling is not worked out.

4.3 Handlers (2.6):
- 4.3.1 What the handler's `return` means: written back into `x` (for example a clamp), or the handler's own value for later statements. If written into `x`, a write from its own handler must not fire it again (or is a build error).
- 4.3.2 `LoopRunProcess` is mutable; check that making one per fired handler is optimized away when everything is inlined, or make one per plan step.

4.4 Every merge of a step's, `init`'s or cleanup's returns goes through `merge(scv, args, demand)`, once per merge. The wrapper is applied after `init`; decide whether cleanup returns fire.
