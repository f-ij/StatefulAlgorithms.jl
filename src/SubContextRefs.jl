#=
Subcontext references: how a user names a subcontext, and how that name becomes a key.

Terms:
- namespace: a part of the context, named by its SCKey. Each registered algorithm or state has
  its own; all calls share `:_captured_returns`; declared locals live in `:_declared_locals`. A `SubContext` holds a
  namespace's values at run time. Plans introduce no namespace: their children have theirs.
  (`Namespace{nothing}` only stands in for one, so plans and algorithms are stepped alike.)
- SCKey: the name of a subcontext in the context: a registry key (`:Sensor_1`), or one of the
  shared subcontexts `:_captured_returns` (captured returns) and `:_declared_locals` (declared locals).
- SCRef: whatever a user writes to say which subcontext they mean: an SCKey, an algorithm or
  state instance, its type, a matcher, or a call. Resolving an SCRef gives its SCKey.
- endpoint: the role of a subcontext in a route or share (its source side or its target side). The endpoint is the namespace; a source or target is a location in it (namespace plus field). Each
  endpoint is written as an SCRef and, once the plan is resolved, is an SCKey.

An SCRef is used in three steps:
1. Store: a route keeps the SCRef in two parts, its matcher type in the route's type
   (`scref_match`) and the object itself until the plan is resolved (`scref_object`).
2. Resolve: once the registry exists, the stored parts give the SCKey (`resolve_scref`).
3. Match: plan options ask whether a plan child is the subcontext an SCRef names
   (`child_matches_scref`).

Matchers are compared as values (`matcher_equals`), never by their type: the stored parts give the matcher value
(`endpoint_matcher`): the object's matcher, or, for an endpoint stored without an object, the matcher made from its
type, which only a matcher without fields can be (`reconstruct_matcher`). A matcher that carries data (`UniquePlanId`)
always keeps its object.
=#

################################################
##################   STORE   ###################
################################################

"""
The matcher an SCRef is found by: an SCKey as a `KeyMatcher`, anything else as its `match_by` made a matcher (a type
as a `TypeMatcher`, a plain value as a `ValMatcher`). What a `Var` holds.
"""
function scref_matcher(ref)
    ref isa Symbol && return KeyMatcher(ref)
    matcher = match_by(ref)
    matcher isa AbstractMatcher && return matcher
    matcher isa Type && return TypeMatcher(matcher)
    return ValMatcher(matcher)
end

"""
The type-level part of an SCRef: an SCKey stays itself, anything else becomes its matcher type.
Only the matcher goes into a route's type, so the object's value identity does not.
"""
scref_match(ref) = ref isa Symbol ? ref : typeof(scref_matcher(ref))

"""
    same_scref(a, b) -> Bool

Whether two SCRefs name the same subcontext before they are in one plan: two SCKeys by name, any other two by `match`
(an SCKey has no matcher, so it names none of them). An SCRef can also be a matcher value (`endpoint_matcher`).
"""
same_scref(a::Symbol, b::Symbol) = a === b
same_scref(a::Symbol, b::B) where {B} = false
same_scref(a::A, b::Symbol) where {A} = false
same_scref(a::A, b::B) where {A, B} = match(a, b)

"""The object part of an SCRef, kept until the plan is resolved; `nothing` when it is already an SCKey."""
scref_object(ref) = ref isa Symbol ? nothing : ref

"""
    endpoint_matcher(match, object) -> SCKey or matcher value

What a stored SCRef (its `scref_match` part `match` and its `scref_object` part `object`) is compared by: an SCKey
stays itself; otherwise the object's matcher (`scref_matcher`), or, without an object, the matcher of type `match`
(`reconstruct_matcher`: only a matcher without fields is stored without its object).
"""
endpoint_matcher(match::Symbol, object) = match
endpoint_matcher(::Type{M}, ::Nothing) where {M} = reconstruct_matcher(M)
endpoint_matcher(::Type{M}, object) where {M} = scref_matcher(object)

"""
The namespace every instance of this kind lives in, given by its SCKey, or `nothing` when each
instance gets its own namespace from the registry. Calls (`Callable`) all live in `:_captured_returns`.
"""
@inline fixed_namespace(_) = nothing

################################################
#################   RESOLVE   ##################
################################################

"""
The SCKey of a stored SCRef, in order:
1. an SCKey is itself;
2. the object's SCKey: its `fixed_namespace`, its own key, or the key the registry gave it;
3. without an object (or one not in the registry): the first registry entry its matcher value matches
   (`endpoint_matcher`, `matcher_sckey`).
"""
@inline resolve_scref(reg::NameSpaceRegistry, match::Symbol, object, role::String) = match
@inline function resolve_scref(reg::NameSpaceRegistry, ::Type{M}, object, role::String) where {M}
    key = object_sckey(reg, object)
    return isnothing(key) ? matcher_sckey(reg, endpoint_matcher(M, object), role) : key
end
# A type SCRef (`Route(a => SomeAlgoType, ...)`) keeps the type as a `DataType` value, which hides it
# from inference; the `TypeMatcher` in the route's type parameters is a matcher without fields, so its value is made
# from it.
@inline resolve_scref(reg::NameSpaceRegistry, ::Type{M}, object::Type, role::String) where {M<:TypeMatcher} =
    matcher_sckey(reg, reconstruct_matcher(M), role)

"""The SCKey of an SCRef's object, or `nothing` when it has none."""
@inline object_sckey(reg::NameSpaceRegistry, ::Nothing) = nothing
# A matcher kept as the object (a `Var`'s matcher, as a `From` wire's source) has no key of its own: it is found as a
# matcher (`matcher_sckey`).
@inline object_sckey(reg::NameSpaceRegistry, ::AbstractMatcher) = nothing
@inline function object_sckey(reg::NameSpaceRegistry, object)
    fixed = fixed_namespace(object)
    return isnothing(fixed) ? getkey(reg, object) : fixed
end
@inline function object_sckey(reg::NameSpaceRegistry, object::AbstractIdentifiableAlgo)
    key = getkey(object)
    return isnothing(key) || key == Symbol() ? getkey(reg, object) : key
end

"""
The SCKey of the first registry entry the matcher value `m` matches: a `TypeMatcher` the first algorithm of its target
type (or a subtype), any other matcher by `matcher_equals` (`findfirst_by_matcher`).
"""
function matcher_sckey(reg::NameSpaceRegistry, m::TypeMatcher{T}, role::String) where {T}
    matches = findall(T, reg)
    isempty(matches) && _scref_not_found_error(reg, m, role)
    return getkey(first(matches))
end
@inline function matcher_sckey(reg::NameSpaceRegistry, m::AbstractMatcher, role::String)
    found = findfirst_by_matcher(reg, m)
    isnothing(found) && _scref_not_found_error(reg, m, role)
    return getkey(found)
end
matcher_sckey(reg::NameSpaceRegistry, m, role::String) = _scref_not_found_error(reg, m, role)

"""
    dynamic_resolve_scref(reg, match, object, role) -> SCKey

`resolve_scref` on values, for `resolve`: the same order, with the registry walked by the lookups on values
(`dynamic_findkey`, `dynamic_findfirst_algotype`, `dynamic_findfirst_matcher`). Compiled once, not once per
registry and matcher.
"""
Base.@nospecializeinfer function dynamic_resolve_scref(@nospecialize(reg::NameSpaceRegistry), @nospecialize(match), @nospecialize(object), role::String)
    match isa Symbol && return match
    match isa Type || throw(MethodError(resolve_scref, (reg, match, object, role)))
    # A type SCRef with a `TypeMatcher` is found by the matcher alone (the `object::Type` method of `resolve_scref`).
    if !(object isa Type && match <: TypeMatcher)
        key = _dynamic_object_sckey(reg, object)
        isnothing(key) || return key
    end
    if match <: TypeMatcher
        found = dynamic_findfirst_algotype(_typematcher_target(match), reg)
        isnothing(found) && _scref_not_found_error(reg, match, role)
        return getkey(found)
    elseif match <: AbstractMatcher
        found = dynamic_findfirst_matcher(endpoint_matcher(match, object), reg)
        isnothing(found) && _scref_not_found_error(reg, match, role)
        return getkey(found)
    end
    _scref_not_found_error(reg, object, role)
end

# `object_sckey` on values.
Base.@nospecializeinfer function _dynamic_object_sckey(@nospecialize(reg::NameSpaceRegistry), @nospecialize(object))
    (isnothing(object) || object isa AbstractMatcher) && return nothing
    if object isa AbstractIdentifiableAlgo
        key = getkey(object)
        return isnothing(key) || key === Symbol() ? dynamic_findkey(reg, object) : key
    end
    fixed = fixed_namespace(object)
    return isnothing(fixed) ? dynamic_findkey(reg, object) : fixed
end

"""The stored SCRef under a new registry, when resolved child wiring is inherited."""
@inline update_scref(reg::NameSpaceRegistry, match::Symbol, ::Nothing) = match
@inline update_scref(reg::NameSpaceRegistry, match, ::Nothing) = reg[resolve_scref(reg, match, nothing, "endpoint")]
@inline update_scref(reg::NameSpaceRegistry, match, object) = update_keys(object, reg)

"""Return the algorithm type carried by a `TypeMatcher` identity."""
_typematcher_target(::Type{<:TypeMatcher{T}}) where {T} = T

@noinline function _scref_not_found_error(reg::NameSpaceRegistry, ref, role::String)
    available = all_keys(reg)
    available_str = isempty(available) ? "<none>" : join(string.(available), ", ")
    error("Wiring references $role not found in registry.\nRequested: $(ref)\nAvailable names: $available_str")
end

################################################
##################   MATCH   ###################
################################################

"""
    child_matches_scref(child, m) -> Bool

Whether the plan child `child` is the subcontext a stored SCRef names, `m` its `endpoint_matcher`: an SCKey names a
keyed child, a `TypeMatcher` a child of that algorithm type (or a subtype), any other matcher a handle whose own
matcher it equals (`matcher_equals`).
"""
function child_matches_scref(child::C, m::Symbol) where {C}
    child isa AbstractIdentifiableAlgo || return false
    return getkey(child) == m
end
function child_matches_scref(child::C, ::TypeMatcher{Target}) where {C, Target}
    if child isa AbstractIdentifiableAlgo
        child_algo = algotype(C)
        return child_algo == Target || (child_algo isa Type && Target isa Type && child_algo <: Target)
    end
    return C == Target || (Target isa Type && C <: Target)
end
function child_matches_scref(child::C, m::AbstractMatcher) where {C}
    child isa AbstractIdentifiableAlgo || return false
    return matcher_equals(match_by(child), m)
end
