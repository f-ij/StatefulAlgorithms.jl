"""
    update_keys(algo, registry) -> keyed algo

`algo` (or the algorithm type `algo`) as `registry` stores it, with the key it has there (`registry[algo]`).
"""
function update_keys(func::F, reg::NameSpaceRegistry) where {F <: ProcessEntity}
    reg[func]
end

function update_keys(::Type{F}, reg::NameSpaceRegistry) where {F <: ProcessEntity}
    reg[F]
end
