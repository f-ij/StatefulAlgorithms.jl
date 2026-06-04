abstract type AbstractKey{S} end
@inline function Base.getproperty(a::A, k::AbstractKey{S}) where {A, S}
    return @inline getproperty(a, S)
end

Base.convert(::Type{Symbol}, k::AbstractKey{S}) where S = S
Base.convert(::Type{String}, k::AbstractKey{S}) where S = String(S)

Base.:(==)(a::AbstractKey{S}, s::Symbol) = S == s
Base.:(==)(s::Symbol, a::AbstractKey{S}) = S == s

struct Key{K}() <: AbstractKey{K} end
Key(s::Symbol) = Key{s}()

struct AutoKey{K} <: AbstractKey{K} end
AutoKey(s::Symbol) = AutoKey{s}()

