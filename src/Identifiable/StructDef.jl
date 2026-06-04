######################################
########## Scoped Algorithms #########
######################################
export IdentifiableAlgo, Unique, Identified

"""
Algorithm assigned to a namespace in a context
    Ids can be used te separate two algorithms with the same name and function

    The scopename will be set before when building a LoopAlgorithm, through the a NameSpaceRegistry
        This is done automatically when composing an algorithm and generally will be along the lines of 
        "Type Name of func"_num
    
    The scopename tells the algorithm where to look in the total context

    Id makes two IdentifiableAlgos different even if they have the same name and function
    This can be used to create multiple instances of the same algorithm with each their own state

    VarAliases are bridges from the scope to the runtime (init, step!, and cleanup) variables that
        the algorithm can get from a context. An alias definex Varname_in_subcontext => Varname_in_algorithm 

    AlgoName can be used when fusing multiple algorithms to give them custom names

"""
struct IdentifiableAlgo{F, Id, VarAliases, AlgoName, Key} <: AbstractIdentifiableAlgo{F, Id, VarAliases, AlgoName, Key}
    func::F
end
