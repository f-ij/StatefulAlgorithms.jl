#=
How lifetimes with their own stop condition (`Until`, `AtLeast`, `RepeatOrUntil`, `AtLeastAtMost`) extend the stop
checks:
1. `process_breakcondition` (AbstractProcesses/Hooks.jl), the process's stop check after every step: a pause or close,
   then the lifetime's condition;
2. `routine_breakcondition` (LoopAlgorithms/Routines/Hooks.jl), a routine child's stop check before every repeat: the
   lifetime's condition only.
`Repeat` and `Indefinite` have no condition of their own and use both defaults.

The two count differently for `AtLeast`: the process loop checks after `inc!`, so it counts with `loopint(process)`
(the steps done plus one); a routine child counts with `done`, the repeats of the child done in this step.
=#

##########################################
########## The process's stop check ######
##########################################

@inline _atleast_reached(process::AbstractProcess, atleast::Int) = loopint(process) > atleast

function process_breakcondition(u::Until{Vars}, process::P, context::C) where {Vars, P <: AbstractProcess, C}
    if @inline !shouldrun(process)
        return true
    else
        return @inline u.cond(getindex(context, Vars...))
    end
end

function process_breakcondition(al::AtLeast{Vars}, process::P, context::C) where {Vars, P <: AbstractProcess, C}
    if @inline !shouldrun(process)
        return true
    elseif @inline !_atleast_reached(process, al.atleast)
        return false
    else
        return @inline al.cond(getindex(context, Vars...))
    end
end

function process_breakcondition(ru::RepeatOrUntil{Vars}, process::P, context::C) where {Vars, P <: AbstractProcess, C}
    if @inline !shouldrun(process)
        return true
    else
        return @inline ru.cond(getindex(context, Vars...))
    end
end

function process_breakcondition(aam::AtLeastAtMost{Vars}, process::P, context::C) where {Vars, P <: AbstractProcess, C}
    if @inline !shouldrun(process)
        return true
    elseif @inline !_atleast_reached(process, aam.atleast)
        return false
    else
        return @inline aam.cond(getindex(context, Vars...))
    end
end

##########################################
########## A routine child's stop check ##
##########################################

@inline routine_breakcondition(spec::U, process::P, context::C, done::LI) where {Vars,U<:Until{Vars},P<:AbstractProcess,C,LI<:Integer} =
    spec.cond(getindex(context, Vars...))

@inline routine_breakcondition(spec::AL, process::P, context::C, done::LI) where {Vars,AL<:AtLeast{Vars},P<:AbstractProcess,C,LI<:Integer} =
    done >= spec.atleast && spec.cond(getindex(context, Vars...))

@inline routine_breakcondition(spec::ROU, process::P, context::C, done::LI) where {Vars,ROU<:RepeatOrUntil{Vars},P<:AbstractProcess,C,LI<:Integer} =
    spec.cond(getindex(context, Vars...))

@inline routine_breakcondition(spec::AAM, process::P, context::C, done::LI) where {Vars,AAM<:AtLeastAtMost{Vars},P<:AbstractProcess,C,LI<:Integer} =
    done >= spec.atleast && spec.cond(getindex(context, Vars...))
