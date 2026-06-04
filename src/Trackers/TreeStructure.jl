is_decomposable(::Any) = false
is_decomposable(r::Routine) = true
is_decomposable(ca::CompositeAlgorithm) = true
# is_decomposable(sr::SubRoutine) = is_decomposable(sr.func)

# getbranch(::Any, idx) = nothing
getbranch(r::Routine, idx) = getalgos(r)[idx]
getbranch(ca::CompositeAlgorithm, idx) = getalgos(ca)[idx]
# getbranch(sr::SubRoutine, idx) = getbranch(sr.func, idx)

nbranches(::Any) = 0
nbranches(r::Routine) = length(getalgos(r))
nbranches(ca::CompositeAlgorithm) = numalgos(ca)

"""
Give the number of total leafs in the algorithm
"""
function num_leafs(pa)
    if !is_decomposable(pa)
        return 1
    end
    return sum(num_leafs(getbranch(pa,i)) for i in 1:nbranches(pa))
end

"""
Get the number of leafs in this branch
"""
function branch_leafs(pa, i)
    num_leafs(getbranch(pa, i))
end

"""
Given a linear index, find the branch that contains it
"""
function upper_branch(r, linearidx)
    branchidx = 1
    while branch_leafs(r, branchidx) < linearidx
        linearidx -= branch_leafs(r, branchidx)
        branchidx += 1
    end
    return branchidx
end

"""
Given a branch, count the number of leafs in preceding branches at the same level
"""
function sum_previous_leafs(r, branchidx)
    if branchidx == 1
        return 0
    end
    sum(branch_leafs(r, i) for i in 1:branchidx-1)
end

function _getleaf(r, linearidx)
    # if r isa Routine || r isa CompositeAlgorithm
    if is_decomposable(r)
        branchidx = upper_branch(r, linearidx)
        linearidx -= sum_previous_leafs(r, branchidx)
        _getleaf(getbranch(r, branchidx), linearidx)
    else
        return r
    end
end

function getleaf(r::ProcessAlgorithm, linearidx)
    _getleaf(r, linearidx)
end

"""
Walk through the tree sequentially
"""
getbranch(tree, idx) = tree[idx+1]

enterbranches(tree, pathidxs...) = enterbranches(getbranch(tree, gethead(pathidxs)), gettail(pathidxs)...)
enterbranches(tree) = tree

function branchpath(f, linearidx)
    if !is_decomposable(f)
        return ()
    end
    @assert linearidx <= num_leafs(f) "Index given exceeds the number of algorithms"
    branchidx = upper_branch(f, linearidx)
    return (branchidx, branchpath(getbranch(f, branchidx), linearidx - sum_previous_leafs(f,branchidx))...)
end

##### NEW IMP
_flattypes(a::Any) = (typeof(a),)
_flattypes(ta::Type) = (ta,)
@generated function _flattypes(caT::Type{<:CompositeAlgorithm{CA}}) where CA
    flat = (Iterators.Flatten(_flattypes.(CA.parameters))...,)
    return :(tuple($(flat)...))
end
_flattypes(ca::CompositeAlgorithm) = _flattypes(typeof(ca))
@generated function _flattypes(rT::Type{<:Routine{RA}}) where RA
    flat = (Iterators.Flatten(_flattypes.(RA.parameters))...,)
    return :(tuple($(flat)...))
end
_flattypes(r::Routine) = _flattypes(typeof(r))

Base.Flatten(pa::ProcessAlgorithm) = _flattypes(pa)
Base.Flatten(paT::Type{PA}) where PA <: ProcessAlgorithm = _flattypes(paT)
"""
Get the unique algorithm types of the flat representation
    In order of the occurrences in the flat representation
"""
@generated function UniqueFlatten(paT::Type{PA}) where PA <: ProcessAlgorithm
    flat = Base.Flatten(PA)
    # error(flat)
    uT = tuple(unique(flat)...)
    return :($uT)
end
UniqueFlatten(pa::ProcessAlgorithm) = UniqueFlatten(typeof(pa))


"""
Get the counts of each unique algorithm type in the Unique representation
"""
typecounts(pa::ProcessAlgorithm) = typecounts(typeof(pa))
@generated function typecounts(paT::Type{PA}) where PA <: ProcessAlgorithm
    flat = Base.Flatten(PA)
    uniques = UniqueFlatten(PA)
    counts = tuple()
    for unique in uniques
        counts = (counts..., count(x -> x == unique, flat))
    end
    return :( $counts )
end


multiplier(a::Any) = 1
multipliers(a::Any) = (1,)
subalgotypes(a::Any) = a

"""
Get the multipliers in the flat representation
"""
flat_multipliers(a::Any) = 1
@generated function flat_multipliers(paT::Type{PA}) where PA <: Union{Routine, CompositeAlgorithm}
    subtypes = subalgotypes(PA)
    mtpliers = multipliers(PA)
    flat = tuple(Base.Flatten(map((s,m) -> m.* flat_multipliers(s), subtypes, mtpliers))...)
    return :($flat)
end
flat_multipliers(pa::ProcessAlgorithm) = flat_multipliers(typeof(pa))


"""
For the flat representation, get the index of the unique representation

E.g. (A,B,C,A,A,C) = (1,2,3,1,1,3)
"""
flatmap(pa::ProcessAlgorithm) = flatmap(typeof(pa))
@generated function flatmap(paT::Type{PA}) where PA <: ProcessAlgorithm
    flat = Base.Flatten(PA)
    uniques = UniqueFlatten(PA)
    fmap = tuple(map(t -> findfirst(==(t), uniques), flat)...)
    return :($fmap)
end

"""
Get the multipliers per algorithm for the unique algorithms only
"""
unique_multipliers(pa::ProcessAlgorithm) = unique_multipliers(typeof(pa))
@generated function unique_multipliers(paT::Type{PA}) where PA <: Union{Routine, CompositeAlgorithm}
    f_mults = flat_multipliers(PA)
    f_map = flatmap(PA)
    uniques = UniqueFlatten(PA)
    mults = zeros(length(uniques))
    for (flat_idx, mult) in enumerate(f_mults)
        mults[f_map[flat_idx]] += mult
    end
    t = tuple(mults...)
    return :( $t )
end

# """
# From the flat representation, get the idxs of the first occurrence of each unique algorithm
# """
# unique_tree_idxs(pa::PrepereHelper) = unique_tree_idxs(typeof(pa.pa))
# @generated function unique_tree_idxs(paT::Type{PA}) where PA <: ProcessAlgorithm
#    uniques = UniqueFlatten(PA)
#    idxs = zeros(length(uniques))
#    for (u_idx, u) in enumerate(uniques)
#         idxs[u_idx] = findfirst(==(u), Base.Flatten(PA))
#    end
# end

