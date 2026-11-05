"""
So that warnings are only printed once per type per session
"""
const warnset = Set{Any}()
"""
Fallback init
"""
function init(t::T, c::Any) where T
    if !in(T, warnset)
        @warn "No init function defined for var $t with type $T, returning empty context"
        push!(warnset, T)
    end
    (;)
end

"""Return the persistent state produced by lifecycle init."""
@inline _init_state_context(context::C, base::B) where {C<:ProcessContext,B<:ProcessContext} = context
@inline _init_state_context(patch::P, base::B) where {P<:NamedTuple,B<:ProcessContext} =
    @inline merge_into_subcontexts(base, patch)

export cleanup
