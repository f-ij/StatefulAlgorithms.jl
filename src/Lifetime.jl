export Repeat, Indefinite, Until, AtLeast, RepeatOrUntil, AtLeastAtMost
export repeats, breakcondition

abstract type Lifetime end

abstract type RepeatLifetime <: Lifetime end
abstract type IndefiniteLifetime <: Lifetime end

Base.:(/)(r::RepeatLifetime, n) = r.repeats / n
repeats(r::RepeatLifetime) = r.repeats

repeats(::IndefiniteLifetime) = Inf
repeats(p::AbstractProcess) = repeats(lifetime(p))


"""
Struct to define the lifetime of a process
Is a struct so that dispatch can be used to choose the appropriate loop during compile time
"""
struct Indefinite <: IndefiniteLifetime end
struct Repeat <: RepeatLifetime
    repeats::Int
end


function breakcondition(lt::Union{Repeat, Indefinite}, process::P, context::C) where {P <: AbstractProcess, C}
    if @inline !shouldrun(process)
        return true
    else
        return false
    end
end
struct Until{Vars, F} <: IndefiniteLifetime
    cond::F
end

Until(cond::Function, Vars...) = Until{Vars, typeof(cond)}(cond)


function breakcondition(u::Until{Vars}, process::P, context::C) where {Vars, P <: AbstractProcess, C}
    if @inline !shouldrun(process)
        return true
    else
        return @inline u.cond(getindex(context, Vars...))
    end
end

struct AtLeast{Vars, F} <: IndefiniteLifetime
    atleast::Int
    cond::F
end

AtLeast(cond::Function, atleast::Int, Vars...) = AtLeast{Vars, typeof(cond)}(atleast, cond)

@inline _atleast_reached(process::AbstractProcess, atleast::Int) = loopint(process) > atleast

function breakcondition(al::AtLeast{Vars}, process::P, context::C) where {Vars, P <: AbstractProcess, C}
    if @inline !shouldrun(process)
        return true
    elseif @inline !_atleast_reached(process, al.atleast)
        return false
    else
        return @inline al.cond(getindex(context, Vars...))
    end
end

struct RepeatOrUntil{Vars, F} <: RepeatLifetime
    repeats::Int
    cond::F
end
repeats(rou::RepeatOrUntil) = rou.repeats


RepeatOrUntil(cond::Function, repeats::Int, Vars...) = RepeatOrUntil{Vars, typeof(cond)}(repeats, cond)

function breakcondition(ru::RepeatOrUntil{Vars}, process::P, context::C) where {Vars, P <: AbstractProcess, C}
    if @inline !shouldrun(process)
        return true
    else
        return @inline ru.cond(getindex(context, Vars...))
    end
end

struct AtLeastAtMost{Vars, F} <: RepeatLifetime
    atleast::Int
    repeats::Int
    cond::F
end
repeats(aam::AtLeastAtMost) = aam.repeats

AtLeastAtMost(cond::Function, atleast::Int, atmost::Int, Vars...) = AtLeastAtMost{Vars, typeof(cond)}(atleast, atmost, cond)

function breakcondition(aam::AtLeastAtMost{Vars}, process::P, context::C) where {Vars, P <: AbstractProcess, C}
    if @inline !shouldrun(process)
        return true
    elseif @inline !_atleast_reached(process, aam.atleast)
        return false
    else
        return @inline aam.cond(getindex(context, Vars...))
    end
end




