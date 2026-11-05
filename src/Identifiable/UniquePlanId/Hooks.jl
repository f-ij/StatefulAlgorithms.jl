"""
    list_field_derived_params(T) -> tuple of (param, field, derive)

The type parameters of `T` that are worked out from one of its fields: parameter `param` is `derive(field value)`.
After a rewrite of the `UniquePlanId`s in a value (`rewrite_unique_ids`), each is worked out again from the rewritten
field, so a stripped or numbered id in a field is stripped or numbered in the type too. A field that is `nothing` keeps
its parameter. Default `()`.
Extended by: `IdentifiableAlgo` (its id from its `matcher` field, `static_id`), and `Route`, `Share`, `Redirect`, `Var`
(their matcher types from their endpoint fields, `scref_match`).
"""
list_field_derived_params(@nospecialize(T)) = ()
