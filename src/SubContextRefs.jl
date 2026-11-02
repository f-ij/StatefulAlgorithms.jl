#=
How a user names a namespace, and how that name is resolved.

Terms:
- namespace: a part of the context, named by its namespace key. Each registered algorithm or state has its own; all
  calls share `:_captured_returns`; declared locals live in `:_declared_locals`. A `SubContext` holds a namespace's
  values at run time. Plans introduce no namespace: their children have theirs. (`Namespace{nothing}` only stands in
  for one, so plans and algorithms are stepped alike.)
- namespace key: the name a namespace is stored under: a registry key (`:Sensor_1`), or one of the shared subcontexts
  `:_captured_returns` (captured returns) and `:_declared_locals` (declared locals).
- nsref: whatever names a namespace before the registry exists: its key, an algorithm or state instance, its type, a
  matcher, or a call. Resolving an nsref gives its namespace key (`resolve_nsref`).
- partref: a slot that names a part of the context: a route's or share's endpoints, a redirect's ends, a `Var`'s
  storage. It holds an nsref; `partref_match`, `partref_object` and `update_partref` store it.
- endpoint: the role of a namespace in a route or share (its source side or its target side); a source or target is a
  location in it (namespace plus field). Each endpoint is a partref and, once the plan is resolved, a namespace key.

A partref is used in three steps:
1. Store: a route keeps it in two parts, its matcher in the route's type (`partref_match`) and the object itself until
   the plan is resolved (`partref_object`).
2. Resolve: once the registry exists, the stored parts give the namespace key (`resolve_nsref`).
3. Match: plan options ask whether a plan child is the namespace an nsref names (`child_matches_nsref`).
=#

################################################
##################   STORE   ###################
################################################

"""
The matcher an nsref that is not a namespace key is found by: its `match_by` made a matcher (a type as a `TypeMatcher`,
a plain value as a `ValMatcher`). What a `Var` holds.
"""
function nsref_matcher(ref)
    matcher = match_by(ref)
    matcher isa AbstractMatcher && return matcher
    matcher isa Type && return TypeMatcher(matcher)
    return ValMatcher(matcher)
end

"""
The type-level part of a partref: a namespace key stays itself, anything else becomes its matcher type.
Only the matcher goes into a route's type, so the object's value identity does not.
"""
partref_match(ref) = ref isa Symbol ? ref : typeof(nsref_matcher(ref))

"""
    same_nsref(a, b) -> Bool

Whether two nsrefs name the same namespace before they are in one plan: two namespace keys by name, any other two by
`match` (a key has no matcher, so it names none of them). An nsref can also be a matcher type, as a route keeps an endpoint
without its object: it matches as itself (`match_by`).
"""
same_nsref(a::Symbol, b::Symbol) = a === b
same_nsref(a::Symbol, b::B) where {B} = false
same_nsref(a::A, b::Symbol) where {A} = false
same_nsref(a::A, b::B) where {A, B} = match(a, b)

"""The object part of a partref, kept until the plan is resolved; `nothing` when it is already a namespace key."""
partref_object(ref) = ref isa Symbol ? nothing : ref

"""
The namespace every instance of this kind lives in, given by its namespace key, or `nothing` when each
instance gets its own namespace from the registry. Calls (`Callable`) all live in `:_captured_returns`.
"""
@inline fixed_namespace(_) = nothing

################################################
#################   RESOLVE   ##################
################################################

"""
The namespace key of a stored nsref, in order:
1. a namespace key is itself;
2. the object's key: its `fixed_namespace`, its own key, or the key the registry gave it;
3. without an object (or one not in the registry): the first registry entry its matcher matches.

The matcher is taken as a type parameter (`::Type{M}`) so each route's resolution is compiled for
its own matcher and stays inferable.
"""
@inline resolve_nsref(reg::NameSpaceRegistry, match::Symbol, object, role::String) = match
@inline function resolve_nsref(reg::NameSpaceRegistry, ::Type{M}, object, role::String) where {M}
    key = object_namespace_key(reg, object)
    return isnothing(key) ? matcher_namespace_key(reg, M, object, role) : key
end
# A type nsref (`Route(a => SomeAlgoType, ...)`) keeps the type as a `DataType` value, which hides it
# from inference; the matcher in the route's type parameters still carries it, so resolve by that.
@inline resolve_nsref(reg::NameSpaceRegistry, ::Type{M}, object::Type, role::String) where {M<:TypeMatcher} =
    matcher_namespace_key(reg, M, object, role)

"""The namespace key of an nsref's object, or `nothing` when it has none."""
@inline object_namespace_key(reg::NameSpaceRegistry, ::Nothing) = nothing
# A matcher kept as the object (a `Var`'s matcher, as a `From` wire's source) has no key of its own: its type finds it.
@inline object_namespace_key(reg::NameSpaceRegistry, ::AbstractMatcher) = nothing
@inline function object_namespace_key(reg::NameSpaceRegistry, object)
    fixed = fixed_namespace(object)
    return isnothing(fixed) ? getkey(reg, object) : fixed
end
@inline function object_namespace_key(reg::NameSpaceRegistry, object::AbstractIdentifiableAlgo)
    key = getkey(object)
    return isnothing(key) || key == Symbol() ? getkey(reg, object) : key
end

"""The namespace key of the first registry entry an nsref's matcher matches."""
function matcher_namespace_key(reg::NameSpaceRegistry, ::Type{M}, object, role::String) where {M<:TypeMatcher}
    matches = findall(_typematcher_target(M), reg)
    isempty(matches) && _nsref_not_found_error(reg, M, role)
    return getkey(first(matches))
end
function matcher_namespace_key(reg::NameSpaceRegistry, ::Type{M}, object, role::String) where {M<:AbstractMatcher}
    for entry in all_algos(reg)
        matches_type(match_by(entry), M) && return getkey(entry)
    end
    _nsref_not_found_error(reg, M, role)
end
matcher_namespace_key(reg::NameSpaceRegistry, match, object, role::String) = _nsref_not_found_error(reg, object, role)

"""
    dynamic_resolve_nsref(reg, match, object, role) -> namespace key

`resolve_nsref` on values, for `resolve`: the same order, with the registry walked by the lookups on values
(`dynamic_findkey`, `dynamic_findfirst_algotype`, `dynamic_findfirst_matcher_type`). Compiled once, not once per
registry and matcher.
"""
Base.@nospecializeinfer function dynamic_resolve_nsref(@nospecialize(reg::NameSpaceRegistry), @nospecialize(match), @nospecialize(object), role::String)
    match isa Symbol && return match
    match isa Type || throw(MethodError(resolve_nsref, (reg, match, object, role)))
    # A type nsref with a `TypeMatcher` is found by the matcher alone (the `object::Type` method of `resolve_nsref`).
    if !(object isa Type && match <: TypeMatcher)
        key = _dynamic_object_namespace_key(reg, object)
        isnothing(key) || return key
    end
    if match <: TypeMatcher
        found = dynamic_findfirst_algotype(_typematcher_target(match), reg)
        isnothing(found) && _nsref_not_found_error(reg, match, role)
        return getkey(found)
    elseif match <: AbstractMatcher
        found = dynamic_findfirst_matcher_type(match, reg)
        isnothing(found) && _nsref_not_found_error(reg, match, role)
        return getkey(found)
    end
    _nsref_not_found_error(reg, object, role)
end

# `object_namespace_key` on values.
Base.@nospecializeinfer function _dynamic_object_namespace_key(@nospecialize(reg::NameSpaceRegistry), @nospecialize(object))
    (isnothing(object) || object isa AbstractMatcher) && return nothing
    if object isa AbstractIdentifiableAlgo
        key = getkey(object)
        return isnothing(key) || key === Symbol() ? dynamic_findkey(reg, object) : key
    end
    fixed = fixed_namespace(object)
    return isnothing(fixed) ? dynamic_findkey(reg, object) : fixed
end

"""The stored partref under a new registry, when resolved child wiring is inherited."""
@inline update_partref(reg::NameSpaceRegistry, match::Symbol, ::Nothing) = match
@inline update_partref(reg::NameSpaceRegistry, match, ::Nothing) = reg[resolve_nsref(reg, match, nothing, "endpoint")]
@inline update_partref(reg::NameSpaceRegistry, match, object) = update_keys(object, reg)

"""Return the algorithm type carried by a `TypeMatcher` identity."""
_typematcher_target(::Type{<:TypeMatcher{T}}) where {T} = T

@noinline function _nsref_not_found_error(reg::NameSpaceRegistry, ref, role::String)
    available = all_keys(reg)
    available_str = isempty(available) ? "<none>" : join(string.(available), ", ")
    error("Wiring references $role not found in registry.\nRequested: $(ref)\nAvailable names: $available_str")
end

################################################
##################   MATCH   ###################
################################################

"""Whether a plan child (type) is the namespace a stored nsref names: a namespace key names a keyed child."""
function child_matches_nsref(::Type{Child}, match::Symbol) where {Child}
    Child <: AbstractIdentifiableAlgo || return false
    return getkey(Child) == match
end

"""A type matcher names a child of that algorithm type (or a subtype)."""
function child_matches_nsref(::Type{Child}, ::Type{<:TypeMatcher{Target}}) where {Child, Target}
    if Child <: AbstractIdentifiableAlgo
        child_algo = algotype(Child)
        return child_algo == Target || (child_algo isa Type && Target isa Type && child_algo <: Target)
    end
    return Child == Target || (Target isa Type && Child <: Target)
end

"""Any other matcher names a keyed child whose own matcher matches."""
function child_matches_nsref(::Type{Child}, match::Type{<:AbstractMatcher}) where {Child}
    Child <: AbstractIdentifiableAlgo || return false
    return matches_type(match_by(Child), match)
end

@inline child_matches_nsref(child, match) = child_matches_nsref(typeof(child), match)
