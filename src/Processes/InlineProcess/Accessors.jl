#=
Getters and setters of `InlineProcess`: its context (and its type), plan and lifetime.
=#

#TODO Improve context semantics
contexttype(::Union{InlineProcess{TD,ContextType}, Type{<:InlineProcess{TD,ContextType}}}) where {TD,ContextType} = ContextType

@inline lifetime(ip::IP) where {IP<:InlineProcess} = ip.lifetime

getalgo(ip::InlineProcess) = ip.algo
"""The `InitArgs`/`Override`/`Interactive` specs the process was built with (resolved, one per target and kind); fixed
for the process's life."""
getspecs(ip::InlineProcess) = ip.specs

"""Make `c` the context of `ip`: later runs start from it."""
@inline setcontext!(ip::InlineProcess, c) = (ip.context = c)
@inline getcontext(ip::InlineProcess) = ip.context::contexttype(ip)
