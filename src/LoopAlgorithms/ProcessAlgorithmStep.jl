@inline _merge_step_return(contextview, ::Nothing, ::PlanWiringView, namespace::Namespace) =
    @inline merge(contextview, nothing)

@inline _merge_step_return(contextview, retval::NamedTuple, wiring::PlanWiringView, namespace::Namespace) =
    @inline merge(contextview, retval, return_demand(wiring, namespace))

"""
Step a raw `ProcessAlgorithm` child through its resolved loop namespace.

Resolved loop plans store raw algorithm values and carry identity separately in
`Namespace{Name}`. The wiring argument is always a `PlanWiringView` in the
current loop runtime, so route/share lookup and return-demand analysis both read
through that view.
"""
@inline function _step!(
    algo::A,
    context::C,
    runtimecontext::RC,
    wiring::W,
    namespace::Namespace{Name},
    process::P,
    lifetime::LT,
) where {A<:ProcessAlgorithm,C<:AbstractContext,RC<:AbstractContext,W<:PlanWiringView,Name,P<:AbstractProcess,LT<:Lifetime}
    contextview = @inline view(
        context,
        runtimecontext,
        algo,
        namespace;
        sharedcontexts = (@inline shares(wiring)),
        sharedvars = (@inline routes(wiring)),
    )
    retval = @inline step!(algo, contextview)
    return @inline _merge_step_return(contextview, retval, wiring, namespace)
end

"""
Step an unscoped root `ProcessAlgorithm` inside the loop runtime.

This is the terminal fallback for algorithms that are executed without a child
namespace. Runtime-only returns are written to `_runtime` only when demanded by
the current plan wiring.
"""
@inline function _step!(
    algo::A,
    context::C,
    runtimecontext::RC,
    wiring::W,
    process::P,
    lifetime::LT,
) where {A<:ProcessAlgorithm,C<:AbstractContext,RC<:AbstractContext,W<:PlanWiringView,P<:AbstractProcess,LT<:Lifetime}
    retval = @inline step!(algo, context)
    runtimecontext = @inline merge_owner_runtime_return(
        runtimecontext,
        Val(:_runtime),
        retval,
        return_demand(wiring, Namespace{:_runtime}()),
    )
    return context, runtimecontext
end
