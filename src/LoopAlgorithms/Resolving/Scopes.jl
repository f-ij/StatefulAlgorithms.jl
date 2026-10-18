#=
URGENT (2026-10-17, from a review; not fixed yet): `_compute_node_scope` calls `_find_returns_read_in_plan` at every node,
and each call walks that node's whole subtree: the work is depth × size of the tree. Compute it once, bottom-up, if
deep plans appear.
=#

############################################################################################
# 4. Scopes
############################################################################################

"""
Make the name of the slot of a declared local (in `_declared_locals`) or a captured return (in `_captured_returns`).
One of the root plan keeps its name; one of a nested plan is suffixed with that plan's position, `x@1.2` (see `Scope`).
`path` is the plan's position, e.g. "1.2". Defined before `_resolve_scopes_typed` (Typed.jl), whose generator calls it.
"""
make_storage_name(name::Symbol, path::String) = isempty(path) ? name : Symbol(name, "@", path)

"""
    _resolve_scopes(plan, Outer, path)

`plan` (with resolved wiring) with the scope of every node set (see `Scope`), and every route that reads a declared
local or a captured return pointed at its slot. `Outer` is the scope the node is in, `path` its position (`"2.1"`, `""`
for the root).

A node's scope is `Outer` with the node's own declared locals, and the returns of the calls directly in it that are
read somewhere in the node. An assignment to a name that is already visible writes that slot: a call in an inner node
that assigns a local or a return of an enclosing node updates it, as an assignment in a Julia loop body updates a
variable of the enclosing function.

Runs once per plan on plain values (names, tuples, types as values): compiled once, not per plan type.
`_resolve_scopes_typed` (Typed.jl) is the inferred version.
"""
Base.@nospecializeinfer function _resolve_scopes(@nospecialize(la::AbstractPlan), @nospecialize(Outer::Type{<:Scope}), path::String)
    wiring = getfield(la, :wiring)
    Sc, returns = _compute_node_scope(la, Outer, path)
    algos = getfield(la, :funcs)
    old_children = getfield(wiring, :child_wiring)
    n = nfields(algos)
    funcs = Vector{Any}(undef, n)
    children = Vector{Any}(undef, n)
    for i in 1:n
        child = getfield(algos, i)
        if child isa LoopSpec
            child = _resolve_scopes(child, Sc, isempty(path) ? string(i) : string(path, ".", i))
            children[i] = getfield(child, :wiring)
        else
            children[i] = _scope_routes_to_storage(getfield(old_children, i), Sc)
        end
        funcs[i] = child
    end
    # The owners were recorded by step 3 (`_resolve_plan_wiring_tree`).
    resets = (; returns, owners = node_resets(typeof(wiring)).owners)
    global_ = getfield(wiring, :global_wiring)
    own_locals = getfield(wiring, :locals)
    children_ = Tuple(children)
    W = Core.apply_type(PlanWiring, typeof(global_), typeof(children_), typeof(own_locals), Sc, resets)
    return rebuild_plan(la, Tuple(funcs), W(global_, children_, own_locals))
end

"""
Compute the scope `Sc` of the plan node `la`, and the storage names of the returns it captures, which entering the node
clears. Returns `(Sc, returns)`. `Outer` is the scope the node is in, `path` its position. `_compute_node_scope_typed`
(Typed.jl) is the inferred version, which also computes the node's owners (here step 3 records them).
"""
Base.@nospecializeinfer function _compute_node_scope(@nospecialize(la::AbstractPlan), @nospecialize(Outer::Type{<:Scope}), path::String)
    outer_locals, outer_returns = Outer.parameters[1], Outer.parameters[2]
    locals = _scoped_names(outer_locals, fieldnames(typeof(getfield(getfield(la, :wiring), :locals))), path)
    read = _find_returns_read_in_plan(la)
    algos = getfield(la, :funcs)
    captured = Symbol[]
    for i in 1:nfields(algos)
        for name in callable_return_names(typeof(getfield(algos, i)))
            name in read && !_haskey_untyped(locals, name) && !_haskey_untyped(outer_returns, name) &&
                !(name in captured) && push!(captured, name)
        end
    end
    Sc = Scope{locals, _scoped_names(outer_returns, Tuple(captured), path)}
    return Sc, Tuple(Symbol[make_storage_name(name, path) for name in captured])
end

"""`inherited` (`(; name = storage_name, ...)`) with `names`, declared in the plan at `path`, added or hiding the inherited ones."""
Base.@nospecializeinfer function _scoped_names(@nospecialize(inherited::NamedTuple), @nospecialize(names::Tuple), path::String)
    isempty(names) && return inherited
    keys_ = Symbol[fieldnames(typeof(inherited))...]
    slots = Symbol[getfield(inherited, i) for i in 1:nfields(inherited)]
    for name in names
        slot = make_storage_name(name, path)
        i = findfirst(==(name), keys_)
        isnothing(i) ? (push!(keys_, name); push!(slots, slot)) : (slots[i] = slot)
    end
    return NamedTuple{Tuple(keys_)}(Tuple(slots))
end

"""
Find every name read from the captured returns anywhere in a plan tree: the inputs of the calls in it, and the names its
routes read from `_captured_returns` (`_find_returns_read_by_route`).
"""
Base.@nospecializeinfer function _find_returns_read_in_plan(@nospecialize(la::AbstractPlan))
    names = Symbol[]
    algos = getfield(la, :funcs)
    children = getfield(getfield(la, :wiring), :child_wiring)
    for i in 1:nfields(algos)
        f = getfield(algos, i)
        if f isa LoopSpec
            _append_unique!(names, _find_returns_read_in_plan(f))
            continue
        end
        _append_unique!(names, callable_input_names(typeof(f)))
        for r in getfield(getfield(children, i), :routes)
            _append_unique!(names, _find_returns_read_by_route(r))
        end
    end
    return names
end
"""
Return whether the named tuple `nt` has the field `name`: `haskey(nt, name)`, compiled once instead of once per
named-tuple type, for code that runs on types as values (resolve, code generation).
"""
_haskey_untyped(@nospecialize(nt::NamedTuple), name::Symbol) = Base.fieldindex(typeof(nt), name, false) != 0
_append_unique!(names::Vector{Symbol}, @nospecialize(new)) = (for name in new; name in names || push!(names, name); end; names)
"""Find the names one route reads from the captured returns: none unless it reads from `_captured_returns`."""
_find_returns_read_by_route(::Route) = ()
_find_returns_read_by_route(r::Route{:_captured_returns}) = getvarnames(r)

"""
The wiring with every route that reads a declared local or a captured return (`Route(:_declared_locals => ..., :y => :x)`)
pointed at its slot in the scope `Sc` (`y`, or `y@1.2` for one declared or captured in a nested plan).
"""
_scope_routes_to_storage(wiring::Wiring, ::Type{Sc}) where {Sc<:Scope} =
    Wiring(map(r -> _route_to_storage(r, Sc), routes(wiring)), shares(wiring))
_route_to_storage(r::Route, ::Type) = r
_route_to_storage(r::Route{:_declared_locals, To, T, RT, V, A}, ::Type{Sc}) where {To, T, RT, V, A, Sc} =
    Route{:_declared_locals, To, T, RT, _storage_names(scope_locals(Sc), V, "local", "declared"), A, Nothing, Nothing}()
_route_to_storage(r::Route{:_captured_returns, To, T, RT, V, A}, ::Type{Sc}) where {To, T, RT, V, A, Sc} =
    Route{:_captured_returns, To, T, RT, _storage_names(scope_returns(Sc), V, "return", "captured by a call"), A, Nothing, Nothing}()

"""The storage names of `names` (a name, or a tuple of them) in `storage` (name ⇒ storage name); an error for one that is not there."""
_storage_names(storage::NamedTuple, names::Tuple, kind, how) = map(name -> _storage_names(storage, name, kind, how), names)
function _storage_names(storage::NamedTuple, name::Symbol, kind, how)
    haskey(storage, name) || construction_error("A route reads the ", kind, " `", name, "`, which is not ", how, " in this plan or an enclosing one.")
    return getproperty(storage, name)
end
