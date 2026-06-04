"""
Strict DSL implementation requirement
====================================

This file must remain a pure syntax-to-constructor lowering layer.

The DSL may only expand user syntax into the normal constructors, options, and
existing runtime types already provided by the package. Do not add custom
runtime behavior here: no new execution wrappers, no custom stepping/init
logic, no hidden runtime carrier types, and no special-case runtime hooks.

In particular, this file should almost never manufacture `IdentifiableAlgo`
objects itself. Identity/key assignment belongs to the normal constructor,
registry, and runtime matching layers. The DSL should lower to the raw entities
the user wrote, plus ordinary `:key => value`, `Route(...)`, and `Share(...)`
surface syntax, and then let the existing runtime machinery relate those raw
entities to keyed registrations later.

If some DSL syntax needs capabilities that the existing constructor/type surface
cannot express, add those facilities elsewhere in the package first and then
lower to them from this file.

The DSL should only reject malformed DSL syntax. It should not add extra
assert-style checking for runtime types, runtime values, or semantic validity
beyond what the existing constructors and runtime structs already enforce
themselves. If a DSL path needs a more readable failure, wrap it in existing
runtime constructor surfaces and let those runtime objects throw the
understandable error there.

Constructor-call routing rule
-----------------------------

For routed DSL entries, the macro must treat the entire expression to the left
of the final route-call brackets as the constructor/entity expression and pass
it through unchanged into the eventual `CompositeAlgorithm`/`Routine`
constructor surface.

Examples:

- `Walker()` lowers as an entry built from `Walker` with no routes
- `InsertNoise(1000)(scale = dt)` lowers as an entry built from
  `InsertNoise(1000)`, with routes taken only from the final `(scale = dt)`
- `Walker()()` means the left side is `Walker()` and the final `()` contributes
  no routes

The DSL layer must not try to initialize or reinterpret that left-hand
constructor expression on its own.

`@context` constraint
---------------------

`@context` is macro-expansion-only syntax. It is not allowed to introduce any
runtime wrapper, helper algorithm, carrier type, custom init/step logic, or
other execution behavior in this file.

Its job is only to let later DSL expressions refer to subcontexts that will
eventually be reachable through a produced algorithm's registry surface. The
lowered result must still be expressed only in terms of the package's normal
constructors and options, ending up as ordinary route/share specifications.

In particular, the intended lowering shape is along the lines of:

- `c1.plus_capture.buffer` -> a normal route source like `plus.plus_capture`
- `c1[plus_capture].buffer` -> a normal route source like `plus[plus_capture]`
- `n.changeable_seed` -> the nested inline-state owner inside `capture_noise`,
  i.e. a normal route source like `capture_noise._state` with source
  `:changeable_seed`

and from there the existing `Route`/`Share` resolution machinery is responsible
for figuring out what those references map to later. The DSL layer must not add
any `Var`-like intermediate structure for this, and it must not attempt to
resolve the runtime registry itself. It also must not validate whether the
lowered endpoint expression is already supported elsewhere; if the rest of the
package rejects it later, that is outside the macro's responsibility.

`@alias` constraint
-------------------

`@alias` is also macro-expansion-only syntax. It is just a naming layer inside
the DSL block:

- `@alias x = Algo` means later `x` refers to `Algo`
- `@alias x = Algo(123)` means later `x` refers to `Algo(123)`
- `x(args...)` rewrites by replacing the root `x` with the aliased expression
- writing the raw aliased expression directly, e.g. `Algo(...)`, does not
  recover the alias name or emit a keyed entry for `x`

The DSL must not impose extra constructor restrictions on aliases beyond normal
Julia syntax.

Identity/keying constraint
--------------------------

The DSL may emit keyed constructor entries like:

- `:name => algo`

because that is part of the ordinary `CompositeAlgorithm` / `Routine`
constructor surface.

But outside of those constructor entries, the default should still be to keep
using raw entities:

- `Route(raw_source => raw_target, ...)`
- `Share(raw_source, raw_target)`

The DSL may wrap those route/share objects in internal location metadata after
parsing so the option is attached to the statement-local plan node instead of
the top-level plan route bucket. To define a top-level plan route/share in the
DSL, write it as an explicit route statement:

- `@route source.x => sink.y`
- `@route source.x => sink.y transform = f reverse_transform = g`

Known `@alias` names and `@context` references are rewritten to their keyed
endpoint in those positions.

There is one deliberate exception: if the DSL already knows the final stable key
for an endpoint at expansion time, it should prefer the keyed owner expression
over the raw value. In practice this means:

- inline `@state` owners should use their known state key (for example `:_state`)
- named aliases used as share/route endpoints should use their known alias key

Why: once the key is already part of the DSL syntax, preserving that keyed
identity in emitted routes/options makes later composition and renaming work
through key replacement instead of depending on raw-value matching. When no
stable key is known yet, the DSL should continue to fall back to raw entities.

Why: keyed/identifiable wrappers are runtime registration artifacts. The normal
matching system is supposed to make keyed registrations comparable to the raw
entities they came from. If the macro manufactures its own `IdentifiableAlgo`
wrappers, it risks creating identities that disagree with what the runtime
would have registered on its own, especially for loop algorithms and nested
DSL-produced entities.
"""
