
"""
    VarLocation{Kind}(subcontextname, originalname, func = nothing, reversefunc = nothing)

Where one name a view sees is stored: the field `originalname` of `subcontextname`. `Kind` says where that is, and the
view's `getproperty` dispatches on it:
- `:state`: a field of the namespace `subcontextname`'s state (the view's own, or another's through a route or share);
- `:runtime`: a runtime value (declared local, input, captured return) in the runtime partition `subcontextname`;
- `:injected`: a value given to the view directly (`SubContextView.injected`).
`originalname` may be a tuple of fields, read together through the read transform `func`; `reversefunc` maps a written
value back onto the fields.
"""
struct VarLocation{Type, subcontextname, originalname, func, reversefunc} end
VarLocation{Type}(subcontextname::Symbol, originalname::ON, func::F = nothing, reversefunc::R = nothing) where {Type, ON <: Union{Tuple, Symbol}, F, R} = VarLocation{Type, subcontextname, originalname, func, reversefunc}()
