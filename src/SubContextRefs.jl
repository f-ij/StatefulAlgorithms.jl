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
1. Store: a route keeps the SCRef in two parts, its matcher in the route's type
   (`scref_match`) and the object itself until the plan is resolved (`scref_object`).
2. Resolve: once the registry exists, the stored parts give the SCKey (`resolve_scref`).
3. Match: plan options ask whether a plan child is the subcontext an SCRef names
   (`child_matches_scref`).
=#

################################################
##################   STORE   ###################
################################################

"""
The type-level part of an SCRef: an SCKey stays itself, anything else becomes its matcher type.
Only the matcher goes into a route's type, so the object's value identity does not.
"""
function scref_match(ref)
    ref isa Symbol && return ref
    matcher = match_by(ref)
    matcher isa AbstractMatcher && return typeof(matcher)
    matcher isa Type && return typeof(TypeMatcher(matcher))
    return typeof(ValMatcher(matcher))
end

"""
    same_scref(a, b) -> Bool

Whether two SCRefs name the same subcontext before they are in one plan: compared by their matchers' data where they
carry it (`UniquePlanId`: by uuid, since separately built plans number their handles alike), else by `scref_match`.
An SCRef can also be a matcher type, as a route keeps an endpoint without its object.
"""
same_scref(a, b) = _scref_identity(a) == _scref_identity(b)
function _scref_identity(ref)
    ref isa Symbol && return ref
    ref isa Type && ref <: AbstractMatcher && return ref
    m = ref isa Type ? nothing : match_by(ref)
    carries_data(m) && return m
    return scref_match(ref)
end

"""The object part of an SCRef, kept until the plan is resolved; `nothing` when it is already an SCKey."""
scref_object(ref) = ref isa Symbol ? nothing : ref

"""
The data part of an SCRef's matcher: the matcher, when it carries data its type does not hold (`carries_data`), else
`nothing`. What a holder that keeps no object (`Var`) keeps next to `scref_match`, so the matcher can be rewritten.
"""
function scref_data(ref)
    ref isa Symbol && return nothing
    m = match_by(ref)
    return carries_data(m) ? m : nothing
end

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
3. without an object (or one not in the registry): the first registry entry its matcher matches.

The matcher is taken as a type parameter (`::Type{M}`) so each route's resolution is compiled for
its own matcher and stays inferable.
"""
@inline resolve_scref(reg::NameSpaceRegistry, match::Symbol, object, role::String) = match
@inline function resolve_scref(reg::NameSpaceRegistry, ::Type{M}, object, role::String) where {M}
    key = object_sckey(reg, object)
    return isnothing(key) ? matcher_sckey(reg, M, object, role) : key
end
# A type SCRef (`Route(a => SomeAlgoType, ...)`) keeps the type as a `DataType` value, which hides it
# from inference; the matcher in the route's type parameters still carries it, so resolve by that.
@inline resolve_scref(reg::NameSpaceRegistry, ::Type{M}, object::Type, role::String) where {M<:TypeMatcher} =
    matcher_sckey(reg, M, object, role)

"""The SCKey of an SCRef's object, or `nothing` when it has none."""
@inline object_sckey(reg::NameSpaceRegistry, ::Nothing) = nothing
# A matcher kept as the object (the data of a `Var`'s matcher, `scref_data`) has no key of its own: its type finds it.
@inline object_sckey(reg::NameSpaceRegistry, ::AbstractMatcher) = nothing
@inline function object_sckey(reg::NameSpaceRegistry, object)
    fixed = fixed_namespace(object)
    return isnothing(fixed) ? getkey(reg, object) : fixed
end
@inline function object_sckey(reg::NameSpaceRegistry, object::AbstractIdentifiableAlgo)
    key = getkey(object)
    return isnothing(key) || key == Symbol() ? getkey(reg, object) : key
end

"""The SCKey of the first registry entry an SCRef's matcher matches."""
function matcher_sckey(reg::NameSpaceRegistry, ::Type{M}, object, role::String) where {M<:TypeMatcher}
    matches = findall(_typematcher_target(M), reg)
    isempty(matches) && _scref_not_found_error(reg, M, role)
    return getkey(first(matches))
end
function matcher_sckey(reg::NameSpaceRegistry, ::Type{M}, object, role::String) where {M<:AbstractMatcher}
    for entry in all_algos(reg)
        matches_type(match_by(entry), M) && return getkey(entry)
    end
    _scref_not_found_error(reg, M, role)
end
matcher_sckey(reg::NameSpaceRegistry, match, object, role::String) = _scref_not_found_error(reg, object, role)

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

"""Whether a plan child (type) is the subcontext a stored SCRef names: an SCKey names a keyed child."""
function child_matches_scref(::Type{Child}, match::Symbol) where {Child}
    Child <: AbstractIdentifiableAlgo || return false
    return getkey(Child) == match
end

"""A type matcher names a child of that algorithm type (or a subtype)."""
function child_matches_scref(::Type{Child}, ::Type{<:TypeMatcher{Target}}) where {Child, Target}
    if Child <: AbstractIdentifiableAlgo
        child_algo = algotype(Child)
        return child_algo == Target || (child_algo isa Type && Target isa Type && child_algo <: Target)
    end
    return Child == Target || (Target isa Type && Child <: Target)
end

"""Any other matcher names a keyed child whose own matcher matches."""
function child_matches_scref(::Type{Child}, match::Type{<:AbstractMatcher}) where {Child}
    Child <: AbstractIdentifiableAlgo || return false
    return matches_type(match_by(Child), match)
end

@inline child_matches_scref(child, match) = child_matches_scref(typeof(child), match)
