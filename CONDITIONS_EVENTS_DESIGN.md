# Conditions and events: design decisions

Two ways for a loop algorithm to run something only some of the time:

- a **condition**, checked when a child is scheduled or a repeat starts: "does this hold now?"
- an **event**, checked when a value is written: "did this write change it?"

Nothing here is built yet. These are the decisions agreed so far, and what is still open.

## 1. Conditions

1.1 `Condition` is the shared field type for "a function plus the `Var`s it reads": `struct Condition{V<:Tuple, F}; cond::F; vars::V; end`, with one hook, `holds(c, context) -> Bool`. The `Var`s stay in a field, not a type parameter (Unique handles keep their id as data).

1.2 `RunIf` becomes `interval` + `condition`. The interval stays a separate, type-level part because `lcm`/unrolling needs it when compiling.

1.3 `Until`, `RepeatOrUntil`, `AtLeast` and `AtLeastAtMost` hold a `condition` field instead of `cond` + `vars`. `lifetime_breakcondition` calls `holds`. `AtLeast*` keeps its `done >= atleast` guard (that reads the repeat count, not the context).

1.4 DSL: plain Julia `if expr … end` / `else` in a block lowers to children scheduled on a `RunIf` with a `Condition`. Assignments inside follow the `@every` rule (the name exists first: `local y`).

1.5 No `Not`/`And`/`Or` types. The DSL folds the whole expression into one generated function (`if x > 0 && !flag` → `Condition((x, flag) -> x > 0 && !flag, Var(x), Var(flag))`); `else` is the same function with `!`.

1.6 No `Once`. "Once at the start" is a child placed before the loop in a routine.

1.7 Conditions that remember something (for example "true every 3rd time `c` holds") are ordinary step algorithms that return a `Bool`, read by the `if`. This is polling, not event handling.

## 2. Events: `OnChange`

2.1 `OnChange` is a **value wrapper**, like `InteractiveVar`. It holds the value and the callback to run.

2.2 The wrapper changes the write action itself. Its `write_value` method is picked by dispatch when compiling and compiles to one inline runtime check: `old !== new && callback(old, new)`. The old value is the one the wrapper holds, so nothing is copied.

2.3 It is written back with its type fixed (`convert(T, new)`), so the context's type doesn't change.

2.4 Scope: **events within the loop algorithm only.** This system is not meant for async compute.
- 2.4.1 An `OnChange` wrapping an `InteractiveVar` is not supported.
- 2.4.2 External writes (`interact!`, `ref[] = v` from another task) don't fire events.
- 2.4.3 A separate facility for those may come later.

2.5 **Runtime values too.** Runtime writes (declared locals, a step's own outputs) don't go through `write_value` today: they are merged directly. `Callable` is altered to return an `OnChange` value into the runtime context, so watched locals fire as well.

2.6 **Arrays changed in place.** For arrays, `OnChange` is a thin wrapper during the run that is not stripped right away:
- 2.6.1 It forwards `getindex`/`setindex!` and sets a flag on `setindex!`.
- 2.6.2 The write check uses that flag instead of `!==`.

2.7 **Callback after the merge.** A new terminating write action carries a callback that is called *after* the merge, so the callback sees the context with the write in it. Running inside `write_value` would see the context from before the write.

2.8 The callback's returns can become write actions: `write_value` may answer a tuple of actions, and `_follow_writes` follows each one, so they go through the hooks again (and may fire other `OnChange`s).

## 3. Open

3.1 2.5: where the comparison happens for a runtime slot that holds an `OnChange` (the runtime merge, `merge_runtime_return`, has to dispatch on the slot's stored value).

3.2 2.6:
- 3.2.1 Writes that bypass `setindex!` (BLAS `mul!`, `parent(x)`, `unsafe_wrap`) don't set the flag.
- 3.2.2 The wrapper must be an `AbstractArray` so broadcasting (`x .= …`) goes through it.
- 3.2.3 Cost of the flag store per element in hot loops, to be measured.

3.3 2.8:
- 3.3.1 The action types are fixed when compiling, so an extra write happens every step. When nothing changed, it writes back the value already there; the callback's result converts to that location's type.
- 3.3.2 How a wrapper's target `Var` becomes a location type when compiling is not worked out.
- 3.3.3 Cycles between handlers: an error when the plan is built.

3.4 Every merge of a step's, `init`'s or cleanup's returns goes through `merge(scv, args, demand)`, once per merge, so a callback also fires on cleanup returns. Decide whether that is wanted.
