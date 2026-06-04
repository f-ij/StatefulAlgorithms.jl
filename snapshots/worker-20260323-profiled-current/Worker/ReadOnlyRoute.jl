export ReadOnlyRoute, readonly

struct ReadOnlyRoute{R<:Route} <: AbstractOption
    route::R
end

function ReadOnlyRoute(from_to::Pair, originalname_or_aliaspairs::Union{Symbol, Pair{Symbol, Symbol}, Pair{NTuple{N, Symbol}, Symbol}}...; transform = nothing) where {N}
    ReadOnlyRoute(Route(from_to, originalname_or_aliaspairs...; transform))
end

readonly(route::Route) = ReadOnlyRoute(route)
readonly(from_to::Pair, originalname_or_aliaspairs::Union{Symbol, Pair{Symbol, Symbol}, Pair{NTuple{N, Symbol}, Symbol}}...; transform = nothing) where {N} =
    ReadOnlyRoute(from_to, originalname_or_aliaspairs...; transform)

@inline _worker_isreadonlyoption(::Any) = false
@inline _worker_isreadonlyoption(::Type) = false
@inline _worker_isreadonlyoption(::ReadOnlyRoute) = true
@inline _worker_isreadonlyoption(::Type{<:ReadOnlyRoute}) = true

@inline _worker_unwrap_option(x) = x
@inline _worker_unwrap_option(r::ReadOnlyRoute) = getfield(r, :route)

@inline _worker_route_type(::Any) = nothing
@inline _worker_route_type(::Type) = nothing
@inline _worker_route_type(r::Route) = typeof(r)
@inline _worker_route_type(::Type{R}) where {R<:Route} = R

@inline function _worker_readonly_option_indices(options::Tuple)
    return tuple((i for i in eachindex(options) if _worker_isreadonlyoption(options[i]))...)
end

@inline function _worker_normalize_options(options::Tuple)
    return map(_worker_unwrap_option, options)
end
