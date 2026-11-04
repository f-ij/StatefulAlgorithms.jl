#=
Getters and setters of `InlineProcess`: its context (and its type), plan and lifetime.
=#

#TODO Improve context semantics
contexttype(::Union{InlineProcess{TD,ContextType}, Type{<:InlineProcess{TD,ContextType}}}) where {TD,ContextType} = ContextType

@inline lifetime(ip::IP) where {IP<:InlineProcess} = ip.lifetime

getalgo(ip::InlineProcess) = ip.algo
"""The `InitArgs`/`Override`/`Interactive` specs the process's context is set up from: those it was built with, merged
with those of later `init!` calls (resolved, one per target and kind)."""
getspecs(ip::InlineProcess) = ip.specs

"""Make `c` the context of `ip`: later runs start from it."""
@inline setcontext!(ip::InlineProcess, c) = (ip.context = c)
@inline getcontext(ip::InlineProcess) = ip.context::contexttype(ip)
