"""
    setup_registry_and_keyed_algos(la) -> (registry, keyed_la)

The registry of the whole tree of `la`, and `la` with every child replaced by its raw algorithm and its key recorded
in its plan's `namespaces` (step 1 of `resolve`).

Generated: which entry types the registry has, which algorithm goes where under which key, the multipliers and the
lookup keys are all decided by `la`'s type, so they are worked out once while compiling (`generate_registry_setup`, the
same walk as on values, run on the types; `setup_registry_generator`). The compiled code only reads the algorithms out
of `la` and puts them in place, and creates each entry type's multipliers and lookup table anew. A plan whose layout
needs its values (a state merge, an object that is not an `IdentifiableAlgo` handle, a plan type not read from its
fields) is set up at run time instead (`setup_registry_from_values`).

The generated code depends on the methods of the layout rules it asked (Registry/Interfaces.jl): when one of them is
added or changed, it is generated again on the next call. A rule method defined after this package was loaded (for an
algorithm of another package, or changed with Revise) cannot be seen while generating; a plan whose layout asks one is
set up at run time.
"""
function setup_registry_and_keyed_algos end

"""
    setup_registry_generator(world, source, self, LA) -> CodeInfo

The body of `setup_registry_and_keyed_algos` for a plan of type `LA`, as a `CodeInfo` that depends on the rule methods
it asked (`codeinfo_with_rule_edges`): `generate_registry_setup(LA)`, or a call to `setup_registry_from_values(la)` when
a rule method it asked was added or changed after this package was loaded (`rules_answered_alike`).
"""
function setup_registry_generator(world::UInt, source::Method, @nospecialize(self), @nospecialize(LA))
    rule_calls = Any[]
    body = Base.ScopedValues.with(() -> generate_registry_setup(LA), RULE_CALLS => rule_calls)
    # A rule method this generator cannot see (defined after it, see `rules_answered_alike`): set up at run time.
    rules_answered_alike(rule_calls, world) || (body = :(setup_registry_from_values(la)))
    return codeinfo_with_rule_edges(world, source, Core.svec(:var"#self#", :la), body, rule_calls)
end

@eval function setup_registry_and_keyed_algos(la::LoopAlgorithm)
    $(Expr(:meta, :generated_only))
    $(Expr(:meta, :generated, setup_registry_generator))
end
