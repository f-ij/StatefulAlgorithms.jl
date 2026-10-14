#=
Generated code that depends on the registry's layout rules (Registry/Interfaces.jl).

A generated function that asks rules while generating (through `ask_rule`) must be generated again when one of
those rule methods is added or changed, as an ordinary function is recompiled when a method it calls changes. The
two functions below make that so: `codeinfo_with_rule_edges` returns the generated body together with the rule
methods it depends on, and `rules_answered_alike` tells whether the generator could see the rule methods of the world
it generates for.

A generator runs in the world its generated function was defined in, not in the world it generates code for: it does
not see rule methods added later (by a package loaded after this one, or redefined with Revise), and
`invoke_in_world` cannot take it to a later world. So a generator that asks rules checks afterwards that the methods
answering its calls are those of the world it generates for (`rules_answered_alike`); if not, it generates code that
asks them at run time instead.
=#

"""
    rules_answered_alike(rule_calls, world) -> Bool

Whether every rule call in `rule_calls` (signatures recorded by `ask_rule` in a generator) is answered by the same
methods in `world` as in the world the generator runs in (`Base.tls_world_age()`). False when a method of a rule that
could answer one of them was added or changed after the generated function was defined.
"""
function rules_answered_alike(rule_calls::Vector{Any}, world::UInt)
    own_world = Base.tls_world_age()
    world == own_world && return true
    for sig in unique(rule_calls)
        now, then = Base._methods_by_ftype(sig, -1, world), Base._methods_by_ftype(sig, -1, own_world)
        (now isa Vector && then isa Vector && length(now) == length(then)) || return false
        all(i -> now[i].method === then[i].method, eachindex(now)) || return false
    end
    return true
end

"""
    codeinfo_with_rule_edges(world, source, argnames, body, rule_calls) -> CodeInfo

The body `body` (an expression) of a generated function, lowered for `world`, depending on the rule methods that were
asked while working it out: `rule_calls` holds the signatures recorded by `ask_rule`. Adding or changing a method that
could answer one of those calls (also with Revise) then makes Julia generate the body again on the next call, as it
does for the methods an ordinary function calls. `source` is the generated method, `argnames` its argument names
(the function itself first).

How: the generator returns a `CodeInfo` (not an expression), whose `edges` list, per recorded call, the methods that
answer it (`(number of methods, signature, method instances...)`, the format inference records for its own calls,
plus a method-table edge when the methods do not cover the signature), and whose valid worlds are those of the
method lookups.
"""
function codeinfo_with_rule_edges(world::UInt, source::Method, argnames::Core.SimpleVector, @nospecialize(body), rule_calls::Vector{Any})
    ci = Core.GeneratedFunctionStub(identity, argnames, Core.svec())(world, source, body)
    edges = ci.edges isa Core.SimpleVector ? Any[ci.edges...] : Any[]
    min_world, max_world = ci.min_world, ci.max_world
    for sig in unique(rule_calls)
        lo, hi = Ref(typemin(UInt)), Ref(typemax(UInt))
        matches = Base._methods_by_ftype(sig, nothing, -1, world, false, lo, hi, Ref{Int32}(0))
        matches isa Vector || continue
        min_world, max_world = max(min_world, lo[]), min(max_world, hi[])
        covers = any(m -> m.fully_covers, matches)
        covers || push!(edges, sig, Core.methodtable)
        push!(edges, covers ? length(matches) : -length(matches), sig)
        for m in matches
            push!(edges, Base.specialize_method(m))
        end
    end
    ci.edges = Core.svec(edges...)
    ci.min_world, ci.max_world = min_world, max_world
    return ci
end
