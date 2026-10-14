"""
    setup_registry_and_keyed_algos(la) -> (registry, keyed_la)

The registry of the whole tree of `la`, and `la` with every child replaced by its raw algorithm and its key recorded
in its plan's `namespaces` (step 1 of `resolve`).

Generated: which entry types the registry has, which algorithm goes where under which key, the multipliers and the
lookup keys are all decided by `la`'s type, so they are worked out once while compiling (`setup_registry_code`, the
same walk as on values, run on the types). The compiled code only reads the algorithms out of `la` and puts them in
place, and creates each entry type's multipliers and lookup table anew. A plan whose layout needs its values (a
state merge, an object that is not an `IdentifiableAlgo` handle, a plan type not read from its fields) is set up at
run time instead (`setup_registry_from_values`).
"""
@generated function setup_registry_and_keyed_algos(la::LoopAlgorithm)
    # Run in the latest world, so that methods defined after this function (for example an algorithm's
    # `autokey_basename`, defined with the algorithm) are seen. Like every generated function, the result is not
    # recompiled when such a method is added after it was generated for a plan type.
    return Base.invoke_in_world(Base.get_world_counter(), setup_registry_code, la)
end
