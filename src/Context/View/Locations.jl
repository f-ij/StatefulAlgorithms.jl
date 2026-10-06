##########################################
########## Variable Locations ############
##########################################

# This is the basis for the viewsystem. Variables in and out get mapped to locations in the full context

#=
What a view sees, by name, and where each name is stored (a `VarLocation`). The kinds:

- state: the view's namespace's own fields (stored context);
- wires: routes and shares written for this child (`Route`, `Share`, `WithWiring`, the DSL);
- declared locals visible to it: resolve gives every child a route from `_declared_locals` per visible local, with
  target `LocalScope()`;
- outputs: declared outputs for a call, its own subcontext outputs for an algorithm (`get_output_locations`);
- injected values.

State and wires are explicit. A route wins over a state field of the same name (it is written for this child); a share
with the same name as a state field or a route is an error. Declared locals and outputs are implicit,
visible to every child of the block whether it uses them or not, so an explicit name hides an implicit one of the same
name; among the implicit ones a declared local hides an output. Injected values hide everything.
=#

"""The view's namespace's state (its subcontext in the stored context), by name."""
get_state_locations(::Type{SCT}) where {SCT<:SubContextView{B, SubKey}} where {B<:ContextBundle, SubKey} = _state_locations(context_part(Val(SubKey)), SCT)

"""A call has no state: its namespace is the declared outputs (see `get_output_locations`)."""
_state_locations(::DeclaredOutputs, ::Type) = (;)

function _state_locations(::Stored, ::Type{SCT}) where {SCT<:SubContextView{B, SubKey}} where {B<:ContextBundle, SubKey}
    _subcontext_type = subcontext_type(SCT)
    _data_type = getdatatype(_subcontext_type)
    state_names = keys(_subcontext_type)
    locations = ntuple(i -> _redirected_varlocation(fieldtype(_data_type, state_names[i]), Val(SubKey), Val(state_names[i])), length(state_names))
    return NamedTuple{(state_names...,)}(locations)
end

"""
    _redirected_varlocation(::Type{T}, Val(subcontext), Val(name))

Overloadable storage-type hook for state fields in `SubContextView`.

The default maps a state field to its location in the stored context. Storage
marker types can overload this to redirect reads and writeback to another
`VarLocation`; `ReplacedVar` uses this to make a state marker behave as a source
field elsewhere in the persistent context.
"""
@inline _redirected_varlocation(::Type{T}, ::Val{SubKey}, ::Val{name}) where {T, SubKey, name} =
    VarLocation{:state}(SubKey, name)

@inline _redirected_varlocation(::Type{T}, ::Val{SubKey}, ::Val{name}) where {VL<:VarLocation, T<:ReplacedVar{VL}, SubKey, name} =
    VL()

"""
Shared subcontexts => VarLocations
"""
@inline _view_shared_types(shared) = shared isa Tuple ? shared : (shared,)

function get_shared_locations(sct::Type{SCT}) where {SCT<:SubContextView{B, SubKey}} where {B<:ContextBundle, SubKey}
    shared_context_names = contextname.(_view_shared_types(view_sharedcontexts(SCT)))

    sharedvars = named_flat_collect_broadcast(shared_context_names) do name
        shared_subcontext_type = subcontext_type(stored_type(B), name)
        shared_varnames = keys(shared_subcontext_type)
        pairs = (shared_varnames[i] => VarLocation{:subcontext}(name, shared_varnames[i]) for i in 1:length(shared_varnames))
        return NamedTuple(pairs)
    end
    return sharedvars
end

"""The routes given to the view: the explicit ones (wires for this child), and the declared locals visible to it."""
_view_routes(::Type{SCT}) where {SCT<:SubContextView} = _view_shared_types(view_sharedvars(SCT))
_is_visible_local(route) = to_match_by(route) isa LocalScope

"""Routes supplied to the view => VarLocations: the explicit routes (`visible_locals = false`) or the visible declared locals."""
function get_routed_locations(::Type{SCT}; visible_locals::Bool = false) where {SCT<:SubContextView}
    return named_flat_collect_broadcast(_view_routes(SCT)) do route
        _is_visible_local(route) == visible_locals || return (;)
        return _routed_locations(context_part(Val(get_fromname(route))), route)
    end
end

"""The locations a route gives the view, read from where its source lives (`location_kind`)."""
function _routed_locations(part::ContextPart, sv)
    fromname = get_fromname(sv)
    _localnames = localnames(sv)
    _subvarcontextnames = subvarcontextnames(sv)
    pairs = (_localnames[i] => VarLocation{location_kind(part)}(fromname, _subvarcontextnames[i], gettransform(sv), getreverse_transform(sv)) for i in 1:length(_localnames))
    return NamedTuple(pairs)
end

"""
The outputs the view sees by name, from the slots typed before the run (Outputs.jl): for a call (namespace
`_declared_outputs`) every declared output, for an algorithm its own subcontext outputs. Implicit: a name the view has
from anything else wins (see `_compute_all_locations`).
"""
function get_output_locations(::Type{SCT}) where {SCT<:SubContextView{B, SubKey}} where {B<:ContextBundle, SubKey}
    names = _output_names(context_part(Val(SubKey)), B, SubKey)
    return NamedTuple{names}(map(name -> VarLocation{:runtime}(SubKey, name), names))
end

"""The data type of a runtime part in runtime context type `RC`; empty when `RC` has no such part."""
function _part_data_type(::Type{RC}, part::ContextPart) where {RC<:ProcessContext}
    D = fieldtype(RC, :subcontexts)
    return part_name(part) in fieldnames(D) ? getdatatype(fieldtype(D, part_name(part))) : NamedTuple{(), Tuple{}}
end

"""The names of the outputs a view sees: a call every declared output, an algorithm its own subcontext outputs."""
_output_names(part::DeclaredOutputs, ::Type{RC}, owner::Symbol) where {RC} = fieldnames(_part_data_type(RC, part))
function _output_names(::Stored, ::Type{RC}, owner::Symbol) where {RC}
    outputs = _part_data_type(RC, SubcontextOutputs())
    return owner in fieldnames(outputs) ? fieldnames(fieldtype(outputs, owner)) : ()
end

function get_injected_locations(sct::Type{SCT}) where {SCT<:SubContextView{B, SubKey}} where {B<:ContextBundle, SubKey}
    injected_vars = injectedfieldnames(SCT)
    injst = ntuple(i ->VarLocation{:injected}(SubKey, injected_vars[i]), length(injected_vars))
    return NamedTuple{(injected_vars...,)}(injst)
end

"""An error for two explicit kinds that give the view the same name."""
function _check_explicit_clashes(::Type{SCT}, kinds::Pair...) where {SCT<:SubContextView{B, SubKey}} where {B<:ContextBundle, SubKey}
    for i in eachindex(kinds), j in (i + 1):length(kinds)
        (name_i, locations_i), (name_j, locations_j) = kinds[i], kinds[j]
        for name in intersect(keys(locations_i), keys(locations_j))
            error("`$(SubKey)` ($(this_instance_type(SCT))) gets `$(name)` both from its $(name_i) and from its $(name_j). Give one of them another name.")
        end
    end
    return nothing
end

this_instance_type(::Type{<:SubContextView{B, SubKey, T}}) where {B, SubKey, T} = T

"""
Everything the view sees, as `(; name => VarLocation)`: see the note above for the kinds and which name wins.
"""
function _compute_all_locations(::Type{SCT}) where {SCT<:SubContextView}
    state = get_state_locations(SCT)
    routes = get_routed_locations(SCT)
    shares = get_shared_locations(SCT)
    # A route wins over a state field of the same name (the route is written for this child); shares may not clash
    # with either.
    _check_explicit_clashes(SCT, "state" => state, "shares" => shares)
    _check_explicit_clashes(SCT, "routes" => routes, "shares" => shares)
    visible_locals = get_routed_locations(SCT; visible_locals = true)
    outputs = get_output_locations(SCT)
    return (; outputs..., visible_locals..., shares..., state..., routes..., get_injected_locations(SCT)...)
end

@inline @generated function _generated_all_locations(::Type{SCT}) where {SCT<:SubContextView}
    locations = _compute_all_locations(SCT)
    return :( $locations )
end

@inline get_all_locations(scv::SubContextView) = @inline get_all_locations(typeof(scv))
@inline get_all_locations(sctv::Type{SCT}) where {SCT<:SubContextView} = _generated_all_locations(SCT)

"""
Where the name `name` (as the algorithm uses it) is stored, and the name it has there: the location and the name, or
`nothing` and the name when the view does not see it. An alias of the view maps the algorithm's name to its own first.
"""
function _compute_location(::Type{SCT}, name::Symbol) where {SCT<:SubContextView}
    subcontext_name = algo_to_subcontext_names(SCT, name)
    locations = _compute_all_locations(SCT)
    hasproperty(locations, subcontext_name) && return getproperty(locations, subcontext_name), subcontext_name
    hasproperty(locations, name) && return getproperty(locations, name), name
    return nothing, subcontext_name
end

###########################################
########### Getting Properties  ###########
###########################################

@inline Base.keys(scv::SCV) where SCV <: SubContextView = @inline propertynames(@inline get_all_locations(scv))
@inline Base.propertynames(scv::SCV) where SCV <: SubContextView = @inline propertynames(@inline get_all_locations(scv))
@inline Base.haskey(scv::SCV, name::Symbol) where SCV <: SubContextView = @inline haskey(get_all_locations(scv), name)
@inline getregistry(scv::SCV) where SCV <: SubContextView = getregistry(getcontext(scv))

"""The runtime values under `subcontextname`: a runtime part (`_declared_outputs`, `_inputs`, ...), or a namespace's outputs."""
@inline function _runtime_subcontext_data(runtimecontext::ProcessContext, ::Val{subcontextname}) where {subcontextname}
    subcontexts = @inline get_subcontexts(runtimecontext)
    haskey(subcontexts, subcontextname) && return getdata(getproperty(subcontexts, subcontextname))
    outputs = @inline get_subcontext_outputs(runtimecontext)
    return haskey(outputs, subcontextname) ? getproperty(outputs, subcontextname) : (;)
end

@inline function _runtime_has_var(runtimecontext, ::Val{subcontextname}, ::Val{varname}) where {subcontextname,varname}
    return haskey(_runtime_subcontext_data(runtimecontext, Val(subcontextname)), varname)
end

@inline function _runtime_get_var(runtimecontext, ::Val{subcontextname}, ::Val{varname}) where {subcontextname,varname}
    return getproperty(_runtime_subcontext_data(runtimecontext, Val(subcontextname)), varname)
end

"""
    subcontext_view_value(value, view)

Return the value exposed by `SubContextView` reads for one stored field.

This is an overloadable API for storage wrappers that need custom
algorithm-facing read behavior. Methods should transform `value` and then call
`subcontext_view_value(next_value, view)` again, so nested wrappers unfold until
the default identity method is reached.
"""
@inline subcontext_view_value(value::T, view::V) where {T, V<:SubContextView} = value

"""Resolve a replaced field through its stored backing location."""
@inline function subcontext_view_value(value::R, view::V) where {VL<:VarLocation, R<:ReplacedVar{VL}, V<:SubContextView}
    return @inline subcontext_view_value(getproperty(view, getfield(value, :varlocation)), view)
end

"""
    subcontext_writeback_value(old, returned)

Return the value that should be written to context when an algorithm returns
`returned` for a field currently storing `old`.

This is an overloadable API for storage wrappers that absorb writes while
preserving their context representation, for example mutable reference wrappers.
"""
@inline subcontext_writeback_value(::Any, returned) = returned

@inline function getproperty_fromsubcontext(
    scv::SCV,
    ::Val{subcontextname},
    ::Val{varname},
) where {SCV<:SubContextView, subcontextname, varname}
    return @inline _read_part(context_part(Val(subcontextname)), scv, Val(subcontextname), Val(varname))
end

"""A runtime part's value is in the runtime context."""
@inline _read_part(::ContextPart, scv::SCV, ::Val{subcontextname}, ::Val{varname}) where {SCV<:SubContextView, subcontextname, varname} =
    @inline subcontext_view_value(_runtime_get_var(getbundle(scv), Val(subcontextname), Val(varname)), scv)

"""A namespace's value: its state, or else one of its outputs."""
@inline function _read_part(::Stored, scv::SCV, ::Val{subcontextname}, ::Val{varname}) where {SCV<:SubContextView, subcontextname, varname}
    bundle = @inline getbundle(scv)
    context = @inline getcontext(scv)
    subcontexts = @inline get_subcontexts(context)
    if haskey(subcontexts, subcontextname)
        subcontext = @inline getproperty(subcontexts, subcontextname)
        if @inline haskey(getdata(subcontext), varname)
            return @inline subcontext_view_value(getproperty(subcontext, varname), scv)
        end
    end
    if @inline _runtime_has_var(bundle, Val(subcontextname), Val(varname))
        return @inline subcontext_view_value(_runtime_get_var(bundle, Val(subcontextname), Val(varname)), scv)
    end
    if haskey(subcontexts, subcontextname)
        subcontext = @inline getproperty(subcontexts, subcontextname)
        return @inline subcontext_view_value(getproperty(subcontext, varname), scv)
    end
    error("Subcontext `$subcontextname` is not available in state or runtime context.")
end

"""
    storedproperty_fromsubcontext(scv, Val(subcontext), Val(varname))

Return the backing value stored for one `SubContextView` location without
applying `subcontext_view_value`. Writeback hooks use this to inspect wrappers
that are hidden from algorithm code during normal reads.
"""
@inline function storedproperty_fromsubcontext(
    scv::SCV,
    ::Val{subcontextname},
    ::Val{varname},
) where {SCV<:SubContextView, subcontextname, varname}
    context = @inline getcontext(scv)
    subcontexts = @inline get_subcontexts(context)
    if haskey(subcontexts, subcontextname)
        subcontext = @inline getproperty(subcontexts, subcontextname)
        if @inline haskey(getdata(subcontext), varname)
            return @inline getproperty(subcontext, varname)
        end
    end
    if @inline _runtime_has_var(getbundle(scv), Val(subcontextname), Val(varname))
        return @inline _runtime_get_var(getbundle(scv), Val(subcontextname), Val(varname))
    end
    error("Variable `$subcontextname.$varname` is not available in state or runtime context.")
end
@inline getinjected(scv::SCV, key) where SCV <: SubContextView = getproperty(getinjected(scv), key)
@inline function Base.get(scv::SCV, name::Symbol, default) where SCV <: SubContextView
    if haskey(scv, name)
        return getproperty(scv, Val(name))
    else
        return default
    end
end

@inline Base.@constprop :aggressive Base.getproperty(sct::SubContextView, v::Symbol) = getproperty(sct, Val(v))
@inline Base.@constprop :aggressive Base.getindex(sct::SubContextView, v::Symbol) = getproperty(sct, Val(v))

# """
# Equivalent to getproperty(sct, Val(name)), but allows for inlining and constant propagation on the name argument
# """
# function Base.getproperty(sct::SubContextView, symb::S) where S <: Symbol
#     locations = get_all_locations(sct)
#     subcontext_name = algo_to_subcontext_names(sct, symb)
#     varlocation = @inline getproperty(locations, subcontext_name)
#     return @inline getproperty(sct, varlocation)
# end

@inline @generated function Base.getproperty(sct::SCV, vl::Union{VarLocation{:subcontext}, VarLocation{:state}}) where SCV <: SubContextView
    target_subcontext = get_subcontextname(vl)
    target_variable = get_originalname(vl)
    if isnothing(getfunc(vl)) && target_variable isa Symbol
        return quote
            return @inline getproperty_fromsubcontext(sct, Val($(QuoteNode(target_subcontext))), Val($(QuoteNode(target_variable))))
        end
    end

    assign_exprs, varsymbols = getvar_expressions_and_varnames(vl)
    fexpr = funcexpr(vl, varsymbols...)
    
    return  quote
        $(assign_exprs...)
        return $(fexpr)
    end
end

"""
Read a routed runtime variable from the runtime context.
"""
@inline @generated function Base.getproperty(sct::SCV, vl::VarLocation{:runtime}) where SCV <: SubContextView
    target_subcontext = get_subcontextname(vl)
    target_variables = get_originalname(vl)
    if isnothing(getfunc(vl)) && target_variables isa Symbol
        return quote
            return @inline subcontext_view_value(_runtime_get_var(getbundle(sct), Val($(QuoteNode(target_subcontext))), Val($(QuoteNode(target_variables)))), sct)
        end
    end

    varnames = target_variables isa Tuple ? target_variables : (target_variables,)
    varsymbols = ntuple(i -> gensym(:runtime_var), length(varnames))
    assign_exprs = [
        :($(varsymbols[i]) = @inline subcontext_view_value(_runtime_get_var(getbundle(sct), Val($(QuoteNode(target_subcontext))), Val($(QuoteNode(varnames[i])))), sct))
        for i in eachindex(varnames)
    ]
    fexpr = funcexpr(vl, varsymbols...)

    return quote
        $(assign_exprs...)
        return $(fexpr)
    end
end

@inline @generated function Base.getproperty(sct::SCV, vl::VarLocation{:injected}) where SCV <: SubContextView
    target_variable = get_originalname(vl)
    return quote
        injected = getinjected(sct)
        return @inline getproperty(injected, $(QuoteNode(target_variable)))
    end
end

@inline @generated function Base.haskey(scv::SCV, v::Val{name}) where {name} where SCV <: SubContextView
    location, subcontext_name = _compute_location(SCV, name)
    has_key = !isnothing(location)
    return :( $has_key )
end

@inline @generated function Base.getproperty(sct::SubContextView{B, SubKey}, v::Val{key}) where {B<:ContextBundle, SubKey, key}    

    target_location, subcontextname = _compute_location(sct, key)
    if !isnothing(target_location)
        return quote 
            $(LineNumberNode(@__LINE__, @__FILE__))
            @inline getproperty(sct, $target_location) 
        end
        else
            locations = get_all_locations(sct)
            available = keys(locations)
            return quote
                # Outputs without slots (inference could not type them before the run, see Outputs.jl): look them up now.
                if @inline _runtime_has_var(getbundle(sct), Val($(QuoteNode(SubKey))), Val($(QuoteNode(key))))
                    return @inline _runtime_get_var(getbundle(sct), Val($(QuoteNode(SubKey))), Val($(QuoteNode(key))))
                end
                if $(QuoteNode(subcontextname)) == $(QuoteNode(key))
                    $(LineNumberNode(@__LINE__, @__FILE__))
                    a_name = $(QuoteNode(key))
                context = getcontext(sct)
                available_names = $available
                sct_name = $(QuoteNode(subcontextname))
                msg = "Variable $(a_name) requested from $(sct) in View: $(SubKey), but not supplied to context. Available names are: $(available_names) \n Context: $(context)"
            else
                msg = "Variable $(a_name) (mapped to $(sct_name)) requested from $(sct) in View: $(SubKey), but not supplied to context. Available names are: $(available_names) \n Context: $(context)"
            end
            error(msg)
        end
    end
end


@inline @generated function Base.iterate(scv::SCV, state = 1) where SCV <: SubContextView
    locations = get_all_locations(scv)
    _keys = keys(locations)
    return quote 
        if state > length($_keys)
            return nothing
        else
            return (($_keys[state], getproperty(scv, getproperty($locations, $_keys[state]))), state + 1)
        end
    end
end


##########################################
"""
From a pair of a namedtuple intended to merge into context from a view
And all locations in the view
    Create a namedtuple (;target_subcontext => (;var1 = value1, var2 = value2,...),...)
"""
function create_merge_tuples_expr(locations::Locs, args) where Locs
    argsnames_to_merge = fieldnames(args)
    subcontext_merge_parameter_exprs = (;)
    for localname in argsnames_to_merge
        varlocation = getproperty(locations, localname)
        target_subcontext = get_subcontextname(varlocation)
        target_variable = get_originalname(varlocation)

        subcontext_nt_parameters = get(subcontext_merge_parameter_exprs, target_subcontext, Expr(:parameters))
        subcontext_merge_parameter_exprs = (;subcontext_merge_parameter_exprs..., target_subcontext => subcontext_nt_parameters)

        kw_expr = Expr(:kw, target_variable, :(getproperty(args, $(QuoteNode(localname)))))
        push!(subcontext_nt_parameters.args, kw_expr)
    end

    total_nt_expr = Expr(:tuple, Expr(:parameters,
            ((Expr(:kw, subctx, Expr(:tuple,Expr(:parameters, parameter_exprs...))) for (subctx, parameter_exprs) in subcontext_merge_parameter_exprs)...
        )
        )
    )
    return total_nt_expr
end
