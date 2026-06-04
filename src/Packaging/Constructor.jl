"""
Build a package from prepared child algorithms.

Child algorithms are converted to `SubPackage` wrappers. Package-local
aliases belong to those wrappers, while `Package` itself only carries the
schedule, init-only states, and call counter.
"""
function Package(funcs::Funcs, intervals::Intervals; states::States = (), aliases = ntuple(_ -> VarAliases(), length(funcs)), name = Symbol()) where {Funcs<:Tuple, Intervals<:Tuple, States<:Tuple}
    length(funcs) == length(intervals) || error("Package needs one interval per child algorithm, got $(length(funcs)) funcs and $(length(intervals)) intervals.")
    length(funcs) == length(aliases) || error("Package needs one alias bucket per child algorithm, got $(length(funcs)) funcs and $(length(aliases)) alias buckets.")
    normalized_intervals = map(interval -> interval isa Interval ? interval : Interval(interval), intervals)
    children = package_children(funcs, aliases)
    registry = package_registry(children, normalized_intervals)
    customname = name == Symbol() || name == "" ? Symbol() : Symbol(name)
    return Package{typeof(children), States, normalized_intervals, customname, typeof(registry)}(children, states, Ref(1), registry)
end

package(args...; kwargs...) = Package(args...; kwargs...)

"""
Build a package from a loop wrapper by packaging its plan and root states.
"""
function Package(la::LoopAlgorithm, name = Symbol())
    return Package(getplan(la), getstates(la), name)
end

"""
Build a package from a composite execution plan.

Route metadata is converted into a child-aligned `aliases` tuple. Root states
from the wrapper/composite are stored as explicit package `states`.
"""
function Package(comp::CompositeAlgorithm, name = Symbol())
    return Package(comp, (), name)
end

function Package(comp::CompositeAlgorithm, states::States, name = Symbol()) where {States<:Tuple}
    identifiable_funcs = getalgos(comp)
    package_intervals = intervals(comp)
    routes = typefilter(Route, getoptions(comp))
    aliases = package_aliases(identifiable_funcs, setup_registry(comp), routes)
    package_states = (states..., getstates(comp)...)
    customname = name == Symbol() || name == "" ? Symbol() : Symbol(name)
    return Package(identifiable_funcs, package_intervals; states = package_states, aliases, name = customname)
end

function package_children(funcs::Funcs, aliases::Aliases) where {Funcs<:Tuple, Aliases<:Tuple}
    return ntuple(i -> SubPackage(getfield(funcs, i), getfield(aliases, i)), length(funcs))
end

function package_registry(children::Children, intervals::Intervals) where {Children<:Tuple, Intervals<:Tuple}
    child_intervals = zip(children, intervals)
    return unrollreplace(SimpleRegistry(), (child_intervals...,)) do registry, child_interval
        child = first(child_interval)
        interval = last(child_interval)
        interval_value = interval isa Interval ? getinterval(interval) : getinterval(Interval(interval))
        registry, _ = add(registry, child, 1 / interval_value)
        return registry
    end
end

@inline varalias_pairs(::VarAliases{StoA, AtoS}) where {StoA, AtoS} = pairs(StoA)
@inline varalias_pairs(::Nothing) = ()

function package_aliases(funcs::Funcs, registry::NameSpaceRegistry, routes::Routes) where {Funcs<:Tuple, Routes<:Tuple}
    return ntuple(i -> package_alias(getfield(funcs, i), registry, routes), length(funcs))
end

@inline package_base_aliases(func) = VarAliases()
@inline package_base_aliases(func::AbstractIdentifiableAlgo) = getvaraliases(func)

function package_alias(func, registry::NameSpaceRegistry, routes::Routes) where {Routes<:Tuple}
    pairs = varalias_pairs(package_base_aliases(func))
    if isempty(routes)
        return VarAliases(;pairs...)
    end
    return package_alias(func, registry, routes, pairs)
end

function package_alias(func, registry::NameSpaceRegistry, routes::Routes, pairs) where {Routes<:Tuple}
    if isempty(routes)
        return VarAliases(;pairs...)
    end

    route = getfield(routes, 1)
    target = getto(route)
    next_pairs = match(func, target) ? (pairs..., route_to_alias_zip(route, registry)...) : pairs
    return package_alias(func, registry, Base.tail(routes), next_pairs)
end
