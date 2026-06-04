@inline getalgos(pkg::Package) = getfield(pkg, :funcs)
@inline getalgo(pkg::Package, idx) = getalgos(pkg)[idx]
@inline Base.getindex(pkg::Package, idx) = getalgo(pkg, idx)
@inline getstates(pkg::Package) = getfield(pkg, :states)
@inline getinc(pkg::Package) = getfield(pkg, :inc)
@inline getregistry(pkg::Package) = getfield(pkg, :registry)
@inline inc(pkg::Package) = getinc(pkg)[]
@inline intervals(::Union{Package{Funcs, States, Intervals}, Type{<:Package{Funcs, States, Intervals}}}) where {Funcs, States, Intervals} = Intervals
@inline interval(pkg::Union{Package, Type{<:Package}}, idx) = intervals(pkg)[idx]
@inline getalgotype(::Union{Package{Funcs}, Type{<:Package{Funcs}}}, idx) where {Funcs} = Funcs.parameters[idx]
@inline numalgos(::Union{Package{Funcs}, Type{<:Package{Funcs}}}) where {Funcs} = length(Funcs.parameters)
@inline reset!(pkg::Package) = (getinc(pkg)[] = 1; reset!.(getalgos(pkg)); pkg)
@inline registry_entrytype(::Type{<:Package}) = Package
@inline getmultiplier(pkg::Package, child) = static_get_multiplier(getregistry(pkg), child)
@inline getname(::Union{Package{Funcs, States, Intervals, CustomName}, Type{<:Package{Funcs, States, Intervals, CustomName}}}) where {Funcs, States, Intervals, CustomName} = CustomName
@inline algoname(pkg::Package) = getname(pkg) == Symbol() ? nothing : getname(pkg)
@inline Base.haskey(::Package) = false
@inline hasautokey(::Package) = false
@inline hasgivenkey(::Package) = false
@inline function hasautokey(pkg::IdentifiableAlgo{P}) where {P<:Package}
    key = getkey(pkg)
    (!isnothing(key) && key != Symbol()) || return false
    name = getname(getalgo(pkg)) == Symbol() ? :Package : getname(getalgo(pkg))
    return startswith(string(key), string(name, "_"))
end

function Autokey(pkg::Package, i::Int, prefix = Symbol())
    name = getname(pkg) == Symbol() ? :Package : getname(pkg)
    key = @inline static_symbol(Symbol(prefix), Symbol(name), :_, i)
    return IdentifiableAlgo(pkg, key; customname = getname(pkg))
end

@inline @generated function inc!(pkg::Package)
    _lcm = lcm(intervals(pkg)...)
    return :(getinc(pkg)[] = mod1(getinc(pkg)[] + 1, $_lcm))
end

@inline function getmultiplier(contextview::SubContextView{CType, SubKey}, instance::AbstractIdentifiableAlgo) where {CType<:ProcessContext, SubKey}
    registered = getregistry(contextview)[SubKey]
    algo = getalgo(registered)
    if algo isa Package
        return getmultiplier(getregistry(contextview), registered) * getmultiplier(algo, instance)
    end
    return getmultiplier(getregistry(contextview), instance)
end

@inline function getmultiplier(contextview::SubContextView{CType, SubKey}, subpackage::SubPackage) where {CType<:ProcessContext, SubKey}
    registry = getregistry(contextview)
    registered = registry[SubKey]
    package = getalgo(registered)
    package_multiplier = static_get_multiplier(registry, registered)
    sub_multiplier = getmultiplier(package, subpackage)
    return package_multiplier * sub_multiplier
end
