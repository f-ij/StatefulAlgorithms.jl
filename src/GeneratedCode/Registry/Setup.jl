"""
    build_registry_and_key_plan(la) -> (registry, keyed_la)

The registry of the whole tree of `la`, and `la` with every child replaced by its raw algorithm and its key recorded
in its plan's `namespaces` (step 1 of `resolve`).

Generated: which entry types the registry has, which algorithm goes where under which key, the multipliers and the
lookup keys are all decided by `la`'s type, so they are worked out once while compiling (`generate_registry_setup`, the
same walk as on values, run on the types). What the type alone decides is a constant in the generated code: the
algorithms and handles whose type is a singleton, tuples of those, and each entry's lookup table (shared by all plans
of the type). The compiled code only reads the other values out of `la`, computes the multipliers from its schedule
(`compute_multiplier`) and makes the structs around them (`build_from_parts`). A plan whose layout needs its values (a state merge, an object that is not an
`IdentifiableAlgo` handle, a plan type not read from its fields) is set up at run time instead
(`build_registry_from_values`).

The layout rules (Registry/Interfaces.jl) are the package's own: the generator sees the rule methods defined when this
file is loaded. A rule method added or changed later (with Revise) is not seen by plan types compiled before.
"""
@generated function build_registry_and_key_plan(la::LoopAlgorithm)
    return generate_registry_setup(la)
end
