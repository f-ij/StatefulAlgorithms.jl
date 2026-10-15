# TODO: can the `ProcessContext` view API be deprecated?

`ProcessContextView.jl` holds the views made from a `ProcessContext` (`view(pc, instance)` and friends). Since
d761965 ("views are made from a bundle") the loop makes every view from a context bundle (`LoopContext`,
`InitContext`); these methods are kept here until we decide whether they can go. Noted 2026-10-15.

To think about:
- A view made from a `ProcessContext` wraps `bundle_of(pc)`: a bundle with no runtime values. It has no inputs,
  declared locals or captured returns, so it shows less than the algorithm sees while stepping.
- `view(context, :name)` / `view(context, Var(...))` on a `ProcessContext` is the ContextExchange ref API
  (`src/Interactive/ContextExchange.jl`, documented in `docs/src/user/interactive.md`). `view(context, instance)`
  returning a `SubContextView` gives `view` a second, unrelated meaning on the same type.
- `view(pc, scv::SubContextView)` ("regenerate from type") calls `inject(scv)` with one argument; no such method
  exists, so it errors when called.
- Remaining caller: `src/Threaded/Step.jl` (`view(base_context, sa)` with a `ProcessContext`). Threaded is broken
  and was never moved to bundles; see the `ThreadedCompositeAlgorithm` items in the top-level `TODO.md`. A fix or
  removal there removes this caller.
