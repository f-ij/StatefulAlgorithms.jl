##########################################
########## Where each name is stored #####
##########################################

# This is the basis for the viewsystem. Variables in and out get mapped to locations in the full context

#=
What a view sees, by name, and where each name is stored (a `VarLocation`). The kinds:

- state: the view's namespace's own fields (persistent context);
- wires: routes and shares written for this child (`Route`, `Share`, `WithWiring`, the DSL);
- the scope its bundle is in (`Scope`): the declared locals, and for a call the captured returns;
- injected values.

State and wires are explicit. A route wins over a state field of the same name (it is written for this child); a share
with the same name as a state field or a route is an error. The scope is implicit, visible to every child of the block
whether it uses it or not, so an explicit name hides a name of the scope. Injected values hide everything.
=#

"""The view's namespace's state (its subcontext in the persistent context), by name."""
get_state_locations(::Type{SCT}) where {SCT<:SubContextView{B, SubKey}} where {B<:ContextBundle, SubKey} = _state_locations(context_partition(Val(SubKey)), SCT)

"""A call has no state: its namespace is the captured returns."""
_state_locations(::CapturedReturns, ::Type) = (;)

function _state_locations(::NamespacePartition, ::Type{SCT}) where {SCT<:SubContextView{B, SubKey}} where {B<:ContextBundle, SubKey}
    _subcontext_type = get_subcontext_type(SCT)
    _data_type = getdatatype(_subcontext_type)
    state_names = keys(_subcontext_type)
    locations = ntuple(i -> _redirected_varlocation(fieldtype(_data_type, state_names[i]), Val(SubKey), Val(state_names[i])), length(state_names))
    return NamedTuple{(state_names...,)}(locations)
end

"""
    _redirected_varlocation(::Type{T}, Val(subcontext), Val(name))

Overloadable storage-type hook for state fields in `SubContextView`.

The default maps a state field to its location in the persistent context. Storage
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
        shared_subcontext_type = get_subcontext_type(persistent_type(B), name)
        shared_varnames = keys(shared_subcontext_type)
        pairs = (shared_varnames[i] => VarLocation{:state}(name, shared_varnames[i]) for i in 1:length(shared_varnames))
        return NamedTuple(pairs)
    end
    return sharedvars
end

"""Routes supplied to the view => VarLocations."""
function get_routed_locations(::Type{SCT}) where {SCT<:SubContextView}
    return named_flat_collect_broadcast(_view_shared_types(view_sharedvars(SCT))) do route
        return _routed_locations(context_partition(Val(get_fromname(route))), route)
    end
end

"""The locations a route gives the view, read from where its source lives (`location_kind`)."""
function _routed_locations(partition::ContextPartition, sv)
    fromname = get_fromname(sv)
    _localnames = localnames(sv)
    _subvarcontextnames = subvarcontextnames(sv)
    pairs = (_localnames[i] => VarLocation{location_kind(partition)}(fromname, _subvarcontextnames[i], gettransform(sv), getreverse_transform(sv)) for i in 1:length(_localnames))
    return NamedTuple(pairs)
end

"""
The names the view sees from the scope its bundle is in (see `Scope`), by name. Only a call (namespace
`_captured_returns`) sees them: the declared locals and captured returns, which its arguments name and its assignment
writes. A declared local hides a captured return: one declared in an inner node over one captured in an outer node. An
algorithm sees none: it reads and writes the block's values only through its wires.
"""
get_scope_locations(::Type{SCT}) where {SCT<:SubContextView{B, SubKey}} where {B<:ContextBundle, SubKey} =
    _scope_locations(context_partition(Val(SubKey)), bundle_scope(B))

_scope_locations(::ContextPartition, ::Type{Sc}) where {Sc<:Scope} = (;)
_scope_locations(::CapturedReturns, ::Type{Sc}) where {Sc<:Scope} =
    (; _runtime_partition_locations(CapturedReturns(), scope_returns(Sc))..., _runtime_partition_locations(DeclaredLocals(), scope_locals(Sc))...)

"""
Return the locations of the names in `slots` within one runtime context partition. `slots` maps each name to the name
it is stored under there: `(; name = storage_name, ...)`.
"""
_runtime_partition_locations(partition::RuntimePartition, slots::NamedTuple) =
    map(storage -> VarLocation{:runtime}(runtime_partition_name(partition), storage), slots)

function get_injected_locations(sct::Type{SCT}) where {SCT<:SubContextView{B, SubKey}} where {B<:ContextBundle, SubKey}
    injected_vars = injectedfieldnames(SCT)
    injst = ntuple(i ->VarLocation{:injected}(SubKey, injected_vars[i]), length(injected_vars))
    return NamedTuple{(injected_vars...,)}(injst)
end

"""
Throws an error when a share gives the view a name that its state or one of its routes also gives it; returns
`nothing` otherwise. A route and a state field may share a name (the route wins), a share may not: the share would be
silently hidden.
"""
function _check_share_clashes(::Type{SCT}, state, routes, shares) where {SCT<:SubContextView{B, SubKey}} where {B<:ContextBundle, SubKey}
    for name in keys(shares)
        other = haskey(state, name) ? "state" : haskey(routes, name) ? "routes" : nothing
        isnothing(other) && continue
        error("`$(SubKey)` ($(this_instance_type(SCT))) gets `$(name)` both from its $(other) and from its shares. Give one of them another name.")
    end
    return nothing
end

this_instance_type(::Type{<:SubContextView{B, SubKey, T}}) where {B, SubKey, T} = T

##########################################
########## All locations of a view #######
##########################################

"""
Everything the view sees, as `(; name => VarLocation)`: see the note above for the kinds and which name wins.
"""
function _compute_all_locations(::Type{SCT}) where {SCT<:SubContextView}
    state = get_state_locations(SCT)
    routes = get_routed_locations(SCT)
    shares = get_shared_locations(SCT)
    _check_share_clashes(SCT, state, routes, shares)
    return (; get_scope_locations(SCT)..., shares..., state..., routes..., get_injected_locations(SCT)...)
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

##########################################
########## Names a view sees #############
##########################################

@inline Base.keys(scv::SCV) where SCV <: SubContextView = @inline propertynames(@inline get_all_locations(scv))
@inline Base.propertynames(scv::SCV) where SCV <: SubContextView = @inline propertynames(@inline get_all_locations(scv))
@inline Base.haskey(scv::SCV, name::Symbol) where SCV <: SubContextView = @inline haskey(get_all_locations(scv), name)
@inline getregistry(scv::SCV) where SCV <: SubContextView = getregistry(getpersistent(scv))

@inline @generated function Base.haskey(scv::SCV, v::Val{name}) where {name} where SCV <: SubContextView
    location, subcontext_name = _compute_location(SCV, name)
    has_key = !isnothing(location)
    return :( $has_key )
end

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
# TODO: Do we really need the generated version?
# function Base.getproperty(sct::SubContextView, symb::S) where S <: Symbol
#     locations = get_all_locations(sct)
#     subcontext_name = algo_to_subcontext_names(sct, symb)
#     varlocation = @inline getproperty(locations, subcontext_name)
#     return @inline getproperty(sct, varlocation)
# end

@inline @generated function Base.getproperty(sct::SubContextView{B, SubKey}, v::Val{key}) where {B<:ContextBundle, SubKey, key}    

    target_location, subcontextname = _compute_location(sct, key)
    if !isnothing(target_location)
        return quote 
            $(LineNumberNode(@__LINE__, @__FILE__))
            @inline getproperty(sct, $target_location) 
        end
    end
    available = keys(_compute_all_locations(sct))
    mapped = subcontextname === key ? "" : " (mapped to $(subcontextname))"
    return quote
        $(LineNumberNode(@__LINE__, @__FILE__))
        error("Variable ", $(QuoteNode(key)), $mapped, " requested from ", sct, " in View: ", $(QuoteNode(SubKey)),
              ", but not supplied to context. Available names are: ", $available, " \n Context: ", getpersistent(sct))
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
########## Reading a location ############
##########################################

@inline @generated function Base.getproperty(sct::SCV, vl::VarLocation{:state}) where SCV <: SubContextView
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
            return @inline view_value(sct, _assigned_value(_runtime_values(getbundle(sct), Val($(QuoteNode(target_subcontext)))), $(QuoteNode(target_variables))))
        end
    end

    varnames = target_variables isa Tuple ? target_variables : (target_variables,)
    varsymbols = ntuple(i -> gensym(:runtime_var), length(varnames))
    assign_exprs = [
        :($(varsymbols[i]) = @inline view_value(sct, _assigned_value(_runtime_values(getbundle(sct), Val($(QuoteNode(target_subcontext)))), $(QuoteNode(varnames[i])))))
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

##########################################
########## Reading a partition ###########
##########################################

@inline function getproperty_fromsubcontext(
    scv::SCV,
    ::Val{subcontextname},
    ::Val{varname},
) where {SCV<:SubContextView, subcontextname, varname}
    return @inline _read_partition(context_partition(Val(subcontextname)), scv, Val(subcontextname), Val(varname))
end

"""
    _read_partition(partition, view, Val(subcontextname), Val(varname))

Return the value a view shows for `subcontextname.varname`.

`subcontextname` is either a namespace (the name of an algorithm or a `@state`), or one of the runtime context's
partitions: `_captured_returns`, `_subcontext_returns`, `_declared_locals`, `_inputs`. `partition` is
`context_partition(Val(subcontextname))`, which says which of the two it is, and each method reads from the matching
place.
Both pass the value through `view_value`, which unwraps storage wrappers such as `ReplacedVar`.
"""
function _read_partition end

"""`subcontextname` is a runtime context partition (`_inputs`, ...): read `varname` from that partition of the runtime context."""
@inline _read_partition(::RuntimePartition, scv::SCV, ::Val{subcontextname}, ::Val{varname}) where {SCV<:SubContextView, subcontextname, varname} =
    @inline view_value(scv, _assigned_value(_runtime_values(getbundle(scv), Val(subcontextname)), varname))

"""`subcontextname` is a namespace: read `varname` from its state, or, if its state has no `varname`, from what its algorithm returned this step (see `storedproperty_fromsubcontext`)."""
@inline _read_partition(::NamespacePartition, scv::SCV, ::Val{subcontextname}, ::Val{varname}) where {SCV<:SubContextView, subcontextname, varname} =
    @inline view_value(scv, storedproperty_fromsubcontext(scv, Val(subcontextname), Val(varname)))

"""
    storedproperty_fromsubcontext(scv, Val(subcontext), Val(varname))

Return the backing value stored for one `SubContextView` location without
applying `view_value`. Writeback hooks use this to inspect wrappers
that are hidden from algorithm code during normal reads.
"""
@inline function storedproperty_fromsubcontext(
    scv::SCV,
    ::Val{subcontextname},
    ::Val{varname},
) where {SCV<:SubContextView, subcontextname, varname}
    persistent_context = @inline getpersistent(scv)
    subcontexts = @inline get_subcontexts(persistent_context)
    if haskey(subcontexts, subcontextname)
        subcontext = @inline getproperty(subcontexts, subcontextname)
        if @inline haskey(getdata(subcontext), varname)
            return @inline getproperty(subcontext, varname)
        end
    end
    runtime_values = @inline _runtime_values(getbundle(scv), Val(subcontextname))
    haskey(runtime_values, varname) && return @inline getfield(runtime_values, varname)
    error("Variable `$subcontextname.$varname` is not available in state or runtime context.")
end

"""
Return the named tuple of runtime values filed under `subcontextname`.

If `subcontextname` is one of the runtime context's fields (`_captured_returns`, `_subcontext_returns`,
`_declared_locals`, `_inputs`), that is the field's contents. Otherwise `subcontextname` is a namespace, and it is what
that namespace's algorithm returned this step besides its state (empty if nothing).
"""
@inline function _runtime_values(runtime_context::ProcessContext, ::Val{subcontextname}) where {subcontextname}
    subcontexts = @inline get_subcontexts(runtime_context)
    haskey(subcontexts, subcontextname) && return getdata(getproperty(subcontexts, subcontextname))
    outputs = @inline get_subcontext_returns(runtime_context)
    return haskey(outputs, subcontextname) ? getproperty(outputs, subcontextname) : (;)
end

"""
    _assigned_value(values, name)

Return `values.name`, the runtime value `name` in one partition of the runtime context. An error when it is not
there: a return read in a step where nothing assigned it (assigned by a child on a schedule, read in the other
steps). Whether it is there is known from the type, so the check costs nothing.
"""
@inline _assigned_value(values::NamedTuple, name::Symbol) = haskey(values, name) ? getfield(values, name) : _throw_unassigned(name)

@noinline _throw_unassigned(name::Symbol) = error("`$name` has no value in this step: it is assigned by a step that does not run in every step (on a schedule). Declare it first (`local $name` in a DSL block, `Local` in a plan) to keep its last value between steps.")

"""Resolve a replaced field through its stored backing location."""
@inline function view_value(view::V, value::R) where {VL<:VarLocation, R<:ReplacedVar{VL}, V<:SubContextView}
    return @inline view_value(view, getproperty(view, getfield(value, :varlocation)))
end

##########################################
########## Unused ########################
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
