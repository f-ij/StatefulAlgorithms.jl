export copyinputs, copyoverrides

"""
    copyinputs(process_or_la)

Return the stored `Init` specs for an initialized process or loop algorithm.
"""
@inline copyinputs(la::ALA) where {ALA<:AbstractLoopAlgorithm} = getstoredinits(la)

"""
    copyoverrides(process_or_la)

Return the stored `Override` specs for an initialized process or loop algorithm.
"""
@inline copyoverrides(la::ALA) where {ALA<:AbstractLoopAlgorithm} = getstoredoverrides(la)
