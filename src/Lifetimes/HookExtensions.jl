#=
How lifetimes with their own stop condition extend the logical stop check `lifetime_breakcondition` (Hooks.jl next to
this file): `Until` and `RepeatOrUntil` stop when their condition holds; `AtLeast` and `AtLeastAtMost` only after at
least `atleast` repeats. `Repeat` and `Indefinite` have no condition of their own and use the default.

The condition reads the variables `Vars` from the context. A pause or close is not checked here: that is
`process_breakcondition` (AbstractProcesses/Hooks.jl).
=#

@inline lifetime_breakcondition(lt::U, context::C, done::D) where {Vars, U<:Until{Vars}, C, D<:Integer} =
    lt.cond(getindex(context, Vars...))

@inline lifetime_breakcondition(lt::ROU, context::C, done::D) where {Vars, ROU<:RepeatOrUntil{Vars}, C, D<:Integer} =
    lt.cond(getindex(context, Vars...))

@inline lifetime_breakcondition(lt::AL, context::C, done::D) where {Vars, AL<:AtLeast{Vars}, C, D<:Integer} =
    done >= lt.atleast && lt.cond(getindex(context, Vars...))

@inline lifetime_breakcondition(lt::AAM, context::C, done::D) where {Vars, AAM<:AtLeastAtMost{Vars}, C, D<:Integer} =
    done >= lt.atleast && lt.cond(getindex(context, Vars...))
