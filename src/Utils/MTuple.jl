using StaticArrays
struct MTuple{Types, N} <: AbstractMTuple{Types}
    data::MVector
end