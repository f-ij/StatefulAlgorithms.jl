#=
`Maybe`: flag-plus-value storage for a declared local that may not hold a value yet (LoopAlgorithms/Locals). The hook
extensions at the end are how a `Maybe` and a local that was never written (`undef`) read, and how a `Maybe` shows,
in the base of reading and writing stored values (Context/StoredValues/Hooks.jl).
=#

"""
Flag-plus-value storage for a local that may not hold a value yet; `value` is undefined while
unset. `Empty` is what an unset local reads as: `Nothing` (reads give `nothing`) or
`UndefInitializer` (reads throw `UndefRefError`).
"""
struct Maybe{T, F<:Unsigned, Empty}
    isset::F      # as wide as T's alignment: a 1-byte Bool would leave padding that gets copied every step
    value::T
    Maybe{T, F, Empty}() where {T, F, Empty} = new{T, F, Empty}(zero(F))
    Maybe{T, F, Empty}(x) where {T, F, Empty} = new{T, F, Empty}(one(F), x)
end
make_maybe_type(::Type{T}, ::Type{Empty}) where {T, Empty} = Maybe{T, _choose_flag_type(T), Empty}
_choose_flag_type(::Type{T}) where {T} = isconcretetype(T) ? (a = Base.datatype_alignment(T); a >= 8 ? UInt64 : a == 4 ? UInt32 : a == 2 ? UInt16 : UInt8) : UInt8
Base.convert(::Type{Maybe{T, F, Empty}}, ::Empty) where {T, F, Empty} = Maybe{T, F, Empty}()
Base.convert(::Type{Maybe{T, F, Empty}}, x) where {T, F, Empty} = Maybe{T, F, Empty}(convert(T, x))
Base.convert(::Type{Maybe{T, F, Empty}}, m::Maybe{T, F, Empty}) where {T, F, Empty} = m   # resolves the method above against Base's `convert(::Type{T}, ::T)`

##########################################
########## Hook extensions ###############
##########################################

_throw_undef() = throw(UndefRefError())

# Reads: a `Maybe` reads as its value, or as `nothing` / an error while unset.
# Through a view and from a `ProcessContext` (a `Var`, `context.x`) alike.
@inline read_value(reader::R, m::Maybe{T, F, Nothing}) where {R<:AbstractContext, T, F} =
    !iszero(getfield(m, :isset)) ? DirectRead(getfield(m, :value)) : DirectRead(nothing)
@inline read_value(reader::R, m::Maybe{T, F, UndefInitializer}) where {R<:AbstractContext, T, F} =
    !iszero(getfield(m, :isset)) ? DirectRead(getfield(m, :value)) : _throw_undef()
# A local declared without a value that no step ever writes keeps its `undef`.
@inline read_value(view::V, ::UndefInitializer) where {V<:SubContextView} = _throw_undef()
