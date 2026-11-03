
"""
What one algorithm (`instance`, in namespace `SubName`) sees of a context bundle (`LoopContext` while stepping,
`InitContext` while initializing): its state, the variables wired to it, and, from the bundle, inputs and the names
of the scope it is in (declared locals, captured returns). `injected` holds values given to it directly.
"""
struct SubContextView{B<:ContextBundle, SubName, T, NT, VarAliases, Shares, Routes} <: AbstractContext
    bundle::B
    instance::T # ScopedInstance for which the view is created
    injected::NT

    function SubContextView{B, SubName, T, NT}(bundle::B, instance::T; inject::NT = (;)) where {B<:ContextBundle, SubName, T, NT}
        new{B, SubName, T, typeof(inject), varaliases(instance), (), ()}(bundle, instance, inject)
    end

    function SubContextView{B, SubName, T, NT, VarAliases, Shares, Routes}(bundle::B, instance::T, inject::NT = (;)) where {B<:ContextBundle, SubName, T, NT, VarAliases, Shares, Routes}
        new{B, SubName, T, typeof(inject), VarAliases, Shares, Routes}(bundle, instance, inject)
    end
end
