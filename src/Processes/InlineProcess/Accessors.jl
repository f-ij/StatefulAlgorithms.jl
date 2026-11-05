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
setlifetime(ip::IP, lt::LT) where {IP<:InlineProcess, LT<:Lifetime} = _construct_inline_process(getalgo(ip), _getcontext_nokeymap(ip), getspecs(ip), lt, getfield(ip, :keymap))

getalgo(ip::InlineProcess) = ip.algo
"""The `InitArgs`/`Override`/`Interactive` specs the process's context is set up from (resolved, one per target and
kind); fixed for the process's life (`init(ip, specs...)` returns a new process with new ones merged in)."""
getspecs(ip::InlineProcess) = ip.specs

"""Make `c` the context of `ip`: later runs start from it. A context from `getcontext` is stored without its
`UniqueKeyMap` (`strip_keymap`)."""
@inline setcontext!(ip::InlineProcess, c) = (ip.context = strip_keymap(c))
"""The context of `ip`, with the plan's `UniqueKeyMap` back in its registry (`with_keymap`), so a `Unique` handle the
user holds is a key found from types: `getcontext(ip)[handle]`. SA's own code reads `_getcontext_nokeymap(ip)`."""
Base.@nospecializeinfer getcontext(@nospecialize(ip::InlineProcess)) = with_keymap(_getcontext_nokeymap(ip), getfield(ip, :keymap))
"""The context of `ip` as SA works with it: without the plan's `UniqueKeyMap` (see `getcontext`)."""
@inline _getcontext_nokeymap(ip::InlineProcess) = ip.context::contexttype(ip)
