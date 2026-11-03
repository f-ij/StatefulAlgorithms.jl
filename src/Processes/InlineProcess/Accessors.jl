#=
Getters and setters of `InlineProcess`: its context (and its type), plan and lifetime.
=#

#TODO Improve context semantics
contexttype(::Union{InlineProcess{TD,ContextType}, Type{<:InlineProcess{TD,ContextType}}}) where {TD,ContextType} = ContextType

@inline lifetime(ip::IP) where {IP<:InlineProcess} = ip.lifetime
@inline getcontext(ip::IP) where {IP<:InlineProcess} = context(ip)

getalgo(ip::InlineProcess) = ip.algo

@inline context(ip::InlineProcess, c) = (ip.context = c)
@inline context(ip::InlineProcess) = ip.context::contexttype(ip)
