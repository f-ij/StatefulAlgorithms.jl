#=
Getters and setters of `InlineProcess`: its context (and its type), plan and lifetime.
=#

#TODO Improve context semantics
contexttype(::Union{InlineProcess{TD,ContextType}, Type{<:InlineProcess{TD,ContextType}}}) where {TD,ContextType} = ContextType

"""The lifetime of `ip`'s runs when `run` is given none (a run can take its own: `run(ip; repeats/lifetime)`)."""
@inline getlifetime(ip::IP) where {IP<:InlineProcess} = ip.default_lifetime

"""
    setlifetime(ip, lt) -> InlineProcess

A new `InlineProcess` with `ip`'s plan, context (the same object) and specs and lifetime `lt`. The lifetime's type is a
type parameter of `InlineProcess`, so there is no `setlifetime!`.
"""
setlifetime(ip::IP, lt::LT) where {IP<:InlineProcess, LT<:Lifetime} = _construct_inline_process(getalgo(ip), getcontext(ip), getspecs(ip), lt)

getalgo(ip::InlineProcess) = ip.algo
"""The `InitArgs`/`Override`/`Interactive` specs the process was built with (resolved, one per target and kind); fixed
for the process's life."""
getspecs(ip::InlineProcess) = ip.specs

"""Make `c` the context of `ip`: later runs start from it."""
@inline setcontext!(ip::InlineProcess, c) = (ip.context = c)
@inline getcontext(ip::InlineProcess) = ip.context::contexttype(ip)
