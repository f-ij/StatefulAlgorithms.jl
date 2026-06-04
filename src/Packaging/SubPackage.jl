"""
Package-local executable child for `Package`.

`SubPackage` is not a root-identifiable registry entry. It carries only the
wrapped algorithm and package-local aliases. The child deliberately has no
context key: package child state lives in the package subcontext, whose key is
carried by the parent `SubContextView`.
"""
struct SubPackage{F, Aliases} <: ProcessAlgorithm
    func::F
end

"""
Wrap `algo` as a child of a `Package`.

Aliases are stored on the child wrapper, mirroring `IdentifiableAlgo` alias
semantics. The wrapped algorithm itself is kept alias-free so package-local
wiring does not leak into standalone use of the algorithm value.
"""
function SubPackage(algo, aliases = VarAliases())
    algo = instantiate(algo)
    return SubPackage{typeof(algo), aliases}(algo)
end

function SubPackage(algo::AbstractIdentifiableAlgo, aliases = getvaraliases(algo))
    child = getalgo(algo)
    return SubPackage{typeof(child), aliases}(child)
end

@inline Base.getkey(::Union{SubPackage, Type{<:SubPackage}}) = nothing
@inline Base.haskey(::SubPackage) = false
@inline getalgo(child::SubPackage) = getfield(child, :func)
@inline getalgos(child::SubPackage) = (getalgo(child),)
@inline getvaraliases(::Union{SubPackage{F, Aliases}, Type{<:SubPackage{F, Aliases}}}) where {F, Aliases} = Aliases
@inline setvaraliases(child::SubPackage, aliases) = setparameter(child, 2, aliases)
@inline setcontextkey(child::SubPackage, key::Symbol) = child
@inline Autokey(child::SubPackage, i::Int, prefix = Symbol()) = child
@inline match_by(::Union{SubPackage{F}, Type{<:SubPackage{F}}}) where {F} = match_by(F)
