# Old API: views made from a `ProcessContext` instead of a context bundle. See TODO.md in this folder.

# Views of a persistent context on its own (looking at a context outside a loop): a bundle with no runtime values.
@inline Base.view(pc::ProcessContext, instance::A, namespace::Namespace; kwargs...) where {A<:ProcessAlgorithm} =
    @inline view(bundle_of(pc), instance, namespace; kwargs...)
@inline Base.view(pc::ProcessContext, instance::SA; kwargs...) where {SA<:AbstractIdentifiableAlgo} =
    @inline view(bundle_of(pc), instance; kwargs...)

@inline function Base.view(pc::ProcessContext{D}, instance::AbstractIdentifiableAlgo{T, nothing}, inject = (;)) where {D, T}
    named_instance = getregistry(pc)[instance]
    return view(pc, named_instance; inject)
end

"""
Create a view from a non-scoped instance by looking it up in the registry
"""
@inline function Base.view(pc::ProcessContext, instance::I, inject = (;)) where I
    reg = getregistry(pc)
    scoped_instance = @inline get(reg, instance, nothing)
    if isnothing(scoped_instance) && instance isa ProcessEntity
        scoped_instance = @inline static_get(reg, typeof(instance))
    elseif isnothing(scoped_instance)
        scoped_instance = @inline static_get(reg, instance)
    end
    b = bundle_of(pc)
    return SubContextView{typeof(b), getkey(scoped_instance), typeof(scoped_instance), typeof(inject)}(b, scoped_instance; inject=inject)
end

"""
Regenerate a SubContextView from its type
"""
@inline function Base.view(pc::PC, scv::CV; inject = (;)) where {PC <: ProcessContext, CV <: SubContextView}
    @inline view(withpersistent(getbundle(scv), pc), this_instance(scv), inject(scv))
end
