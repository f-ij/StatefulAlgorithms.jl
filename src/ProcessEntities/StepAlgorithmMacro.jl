"""
    @init((; n = 10, ...))

The values a `@StepAlgorithm` uses only to build its `@managed` state. In the signature it declares them
(`@init((; n::Int, scale = 2.0))`, last of the keywords); in a direct call it passes them:

```julia
step!(MyAlgo(), input; @init((; n = 10)))
```

As a call argument it is the keyword `_init = (; n = 10)`.
"""
macro init(ex)
    return Expr(:kw, :_init, esc(ex))
end

"""Deprecated alias for [`@init`](@ref). In a block, `@input x` is a block input, which is something else."""
macro input(ex)
    _sa_warn_init_alias(Symbol("@input"))
    return Expr(:kw, :_init, esc(ex))
end

"""Deprecated alias for [`@init`](@ref)."""
macro inputs(ex)
    _sa_warn_init_alias(Symbol("@inputs"))
    return Expr(:kw, :_init, esc(ex))
end

_sa_warn_init_alias(name::Symbol) =
    @warn "`$name((; ...))` is deprecated for the values that build `@managed` state; use `@init((; ...))` instead." maxlog = 1

_sa_is_macrocall(ex, names::Symbol...) =
    ex isa Expr && ex.head == :macrocall && any(name -> ex.args[1] == name, names)

_sa_is_init_macro(ex) = _sa_is_macrocall(ex, Symbol("@init"), Symbol("@input"), Symbol("@inputs"))
_sa_is_config_macro(ex) = _sa_is_macrocall(ex, Symbol("@config"))
_sa_is_inline_macro(ex) = ex isa Expr && ex.head == :macrocall &&
    (ex.args[1] == Symbol("@inline") || ex.args[1] == Expr(:., :Base, QuoteNode(Symbol("@inline"))))
_sa_read_macro_args(ex) = [arg for arg in ex.args[2:end] if !(arg isa LineNumberNode)]

function _sa_unwrap_where(ex)
    where_params = Any[]
    while ex isa Expr && ex.head == :where
        push!(where_params, ex.args[2])
        ex = ex.args[1]
    end
    return ex, reverse(where_params)
end

function _sa_rewrap_where(ex, where_params)
    for param in where_params
        ex = Expr(:where, ex, param)
    end
    return ex
end

function _sa_split_binding(ex)
    if ex isa Symbol
        return ex, nothing
    elseif ex isa Expr && ex.head == :(::)
        return ex.args[1], ex.args[2]
    end
    error("Unsupported argument declaration: $ex")
end

_sa_build_binding(name::Symbol, typeexpr) = isnothing(typeexpr) ? name : Expr(:(::), name, typeexpr)

function _sa_parse_kw_decl(ex)
    @assert ex isa Expr && ex.head == :kw "Expected keyword declaration, got $ex"
    name, typeexpr = _sa_split_binding(ex.args[1])
    return (; name, typeexpr, default = ex.args[2])
end

"""
    _sa_parse_config_decl(ex) -> (; name, typeexpr, bound, default)

One `@config` field: `name = default`, `name::T = default` or `name <: S = default`. `typeexpr` is the declared type
of `name::T` (`nothing` otherwise); `bound` is `S` of `name <: S` (`nothing` otherwise). A field without a declared
type gets a type parameter of the algorithm's struct (bounded by `S` when given), so it is stored with the type of its
value, never as `Any`.
"""
function _sa_parse_config_decl(ex)
    ex isa Expr && ex.head == :(=) || error("@config fields must use `name = default`, `name::T = default` or `name <: S = default`, got $ex")
    lhs = ex.args[1]
    if lhs isa Expr && lhs.head == :(<:) && length(lhs.args) == 2 && lhs.args[1] isa Symbol
        return (; name = lhs.args[1], typeexpr = nothing, bound = lhs.args[2], default = ex.args[2])
    end
    name, typeexpr = _sa_split_binding(lhs)
    return (; name, typeexpr, bound = nothing, default = ex.args[2])
end

"""The type parameter of the algorithm's struct that holds the type of the `@config` field `name` (`T_name`)."""
_sa_config_typeparam_name(name::Symbol) = Symbol(:T_, name)

function _sa_parse_config_macro(ex)
    _sa_is_config_macro(ex) || error("Expected @config declaration, got $ex")

    entries = Any[]
    for arg in _sa_read_macro_args(ex)
        if arg isa Expr && arg.head == :block
            append!(entries, [item for item in arg.args if !(item isa LineNumberNode)])
        else
            push!(entries, arg)
        end
    end

    isempty(entries) && error("@config requires at least one defaulted field.")
    return map(_sa_parse_config_decl, entries)
end

"""
Split the `@StepAlgorithm` input into `(function_ex, config_fields, force_inline)`.
`force_inline` is true when the user wrote `@inline` on the function definition.
"""
function _sa_split_definition(ex)
    if ex isa Expr && ex.head == :function
        return ex, NamedTuple[], false
    elseif _sa_is_inline_macro(ex)
        args = _sa_read_macro_args(ex)
        length(args) == 1 || error("@inline used with @StepAlgorithm must wrap exactly one function definition.")
        function_ex, config_fields, _ = _sa_split_definition(args[1])
        return function_ex, config_fields, true
    elseif _sa_is_config_macro(ex)
        args = _sa_read_macro_args(ex)
        isempty(args) && error("@config requires at least one field and a function definition when used with @StepAlgorithm.")
        length(args) >= 2 || error("@config used with @StepAlgorithm must wrap a function definition.")

        function_ex, nested_config_fields, force_inline = _sa_split_definition(args[end])
        config_macro = Expr(:macrocall, Symbol("@config"), LineNumberNode(0, Symbol("none")), args[1:end-1]...)
        config_fields = _sa_parse_config_macro(config_macro)
        append!(config_fields, nested_config_fields)
        return function_ex, config_fields, force_inline
    elseif ex isa Expr && ex.head == :block
        statements = [stmt for stmt in ex.args if !(stmt isa LineNumberNode)]
        is_definition(stmt) = stmt isa Expr && (stmt.head == :function || _sa_is_inline_macro(stmt))
        function_defs = [stmt for stmt in statements if is_definition(stmt)]
        length(function_defs) == 1 || error("@StepAlgorithm block form requires exactly one function definition.")

        config_fields = NamedTuple[]
        for stmt in statements
            if stmt === only(function_defs)
                continue
            elseif _sa_is_config_macro(stmt)
                append!(config_fields, _sa_parse_config_macro(stmt))
            else
                error("@StepAlgorithm block form only supports `@config ...` statements plus one function definition. Got `$stmt`.")
            end
        end

        function_ex, _, force_inline = _sa_split_definition(only(function_defs))
        return function_ex, config_fields, force_inline
    end
    error("@StepAlgorithm expects a function definition or a block containing `@config` declarations and one function definition.")
end

function _sa_parse_init_tuple(ex)
    ex isa Expr && ex.head == :tuple || error("@init expects a named tuple, `@init((; a, b = 1))`, got $ex")
    !isempty(ex.args) || return NamedTuple[]
    params = ex.args[1]
    params isa Expr && params.head == :parameters || error("@init expects a named tuple, `@init((; a, b = 1))`, got $ex")

    fields = NamedTuple[]
    for arg in params.args
        if arg isa Expr && arg.head == :kw
            name, typeexpr = _sa_split_binding(arg.args[1])
            push!(fields, (; name, typeexpr, default = arg.args[2], required = false))
        else
            name, typeexpr = _sa_split_binding(arg)
            push!(fields, (; name, typeexpr, default = nothing, required = true))
        end
    end
    return fields
end

function _sa_parse_managed_arg(ex)
    if ex isa Expr && ex.head == :(=)
        name, typeexpr = _sa_split_binding(ex.args[1])
        return (; kind = :managed, name, typeexpr, init_source = :default, init_expr = ex.args[2])
    end
    name, typeexpr = _sa_split_binding(ex)
    return (; kind = :managed, name, typeexpr, init_source = :context, init_expr = nothing)
end

function _sa_parse_positional_arg(ex)
    if _sa_is_macrocall(ex, Symbol("@managed"))
        return map(_sa_parse_managed_arg, _sa_read_macro_args(ex))
    elseif ex isa Expr && ex.head == :(=)
        error("Only @managed positional arguments may have defaults, got $ex")
    else
        name, typeexpr = _sa_split_binding(ex)
        return [(; kind = :plain, name, typeexpr)]
    end
end

function _sa_parse_signature(call_ex)
    call_ex, where_params = _sa_unwrap_where(call_ex)
    call_ex isa Expr && call_ex.head == :call || error("@StepAlgorithm expects a function definition")

    fname = call_ex.args[1]
    args = call_ex.args[2:end]
    params = nothing
    if !isempty(args) && args[1] isa Expr && args[1].head == :parameters
        params = args[1]
        args = args[2:end]
    end

    positional = Any[]
    for arg in args
        append!(positional, _sa_parse_positional_arg(arg))
    end
    plain_pos = filter(x -> x.kind == :plain, positional)
    managed_pos = filter(x -> x.kind == :managed, positional)

    normal_kwargs = NamedTuple[]
    init_fields = NamedTuple[]
    config_fields = NamedTuple[]
    if !isnothing(params)
        for (idx, arg) in enumerate(params.args)
            if _sa_is_init_macro(arg)
                idx == length(params.args) || error("@init must be the last keyword-like argument in @StepAlgorithm")
                isempty(init_fields) || error("Only one @init block is allowed in @StepAlgorithm")
                arg.args[1] == Symbol("@init") || _sa_warn_init_alias(arg.args[1])
                init_fields = _sa_parse_init_tuple(arg.args[end])
            elseif _sa_is_config_macro(arg)
                append!(config_fields, _sa_parse_config_macro(arg))
            else
                push!(normal_kwargs, _sa_parse_kw_decl(arg))
            end
        end
    end

    return (; fname, positional, plain_pos, managed_pos, normal_kwargs, init_fields, config_fields, where_params)
end

_sa_build_read(ctx, name::Symbol, default) = :(get($ctx, $(QuoteNode(name)), $default))

function _sa_build_required_read(ctx, name::Symbol)
    quote
        if !haskey($ctx, $(QuoteNode(name)))
            error("Missing required init value $(string($(QuoteNode(name))))")
        end
        getproperty($ctx, $(QuoteNode(name)))
    end
end

_sa_build_local_assignment(name::Symbol, value_expr) = :(local $name = $value_expr)

function _sa_bind_init_field(field, ctxsym, tempsym; visible = true)
    getexpr = field.required ? _sa_build_required_read(ctxsym, field.name) : _sa_build_read(ctxsym, field.name, field.default)
    exprs = Any[:(local $tempsym = $getexpr)]
    visible && push!(exprs, _sa_build_local_assignment(field.name, tempsym))
    return exprs
end

"""
Build the code that reads each `@init` value from `ctxsym` into its hidden temp (`init_temps`), and into a local of
its own name when it is in `visible_names` (all of them by default).
"""
function _sa_bind_init_fields(fields, ctxsym, init_temps; visible_names = nothing)
    assignments = Any[]
    for field in fields
        visible = isnothing(visible_names) || (field.name in visible_names)
        append!(assignments, _sa_bind_init_field(field, ctxsym, init_temps[field.name]; visible))
    end
    return assignments
end

function _sa_bind_managed_field(field, init_temps, ctxsym)
    value_expr = if field.init_source == :default
        field.init_expr
    elseif haskey(init_temps, field.name)
        init_temps[field.name]
    else
        _sa_build_required_read(ctxsym, field.name)
    end
    return _sa_build_local_assignment(field.name, value_expr)
end

function _sa_bind_runtime_keyword(field, ctxsym)
    return _sa_build_local_assignment(field.name, _sa_build_read(ctxsym, field.name, field.default))
end

function _sa_bind_runtime_positional(field, ctxsym)
    return _sa_build_local_assignment(field.name, :(getproperty($ctxsym, $(QuoteNode(field.name)))))
end

function _sa_bind_config_fields(fields, algosym)
    return [_sa_build_local_assignment(field.name, :(getfield($algosym, $(QuoteNode(field.name))))) for field in fields]
end

"""
    @update x
    @update x = value
    @update x, y
    @update begin x = value; y end

Inside a `@StepAlgorithm` body: write `x` back when the step returns, to where the algorithm read it from (its
`@managed` state, or the variable of the block passed as `x`). The value written is `x`'s value at the `return`.
`@update x = value` (or `@update x += value`, ...) assigns and marks `x` in one line. `x` is an argument of the algorithm. A plain `x = value`
without `@update` only changes the body's local `x`, as in any Julia function.
"""
macro update(args...)
    error("`@update` is only valid inside a `@StepAlgorithm` body.")
end

_sa_is_update(ex) = _sa_is_macrocall(ex, Symbol("@update"))
# `@update x += v` and the other updating operators.
const _SA_UPDATING_OPERATORS = (:+=, :-=, :*=, :/=, :\=, :÷=, :%=, :^=, :&=, :|=, :⊻=, :<<=, :>>=, :>>>=)
# Expressions whose `return`s and `@update`s belong to another function, or are not code.
_sa_is_opaque(ex) = ex isa Expr && ex.head in (:function, :->, :quote)

"""
Rewrite each `@update` in `ex` as plain Julia (`@update x = v` becomes `x = v`; a bare `@update x` becomes `nothing`)
and push the updated names to `names`. Returns the rewritten expression.
"""
function _sa_rewrite_updates!(ex, names::Vector{Symbol})
    ex isa Expr || return ex
    _sa_is_opaque(ex) && return ex
    _sa_is_update(ex) || return Expr(ex.head, (_sa_rewrite_updates!(a, names) for a in ex.args)...)
    args = [a for a in ex.args[2:end] if !(a isa LineNumberNode)]
    length(args) == 1 || error("`@update` takes one argument: `@update x`, `@update x = v`, `@update x, y` or `@update begin ... end`. Got `$ex`.")
    return _sa_rewrite_update!(only(args), names)
end

"""Rewrite the argument of one `@update` (`x`, `x = v`, `x += v`, `x, y` or a block) as plain Julia, pushing its names to `names`."""
function _sa_rewrite_update!(arg, names::Vector{Symbol})
    if arg isa Symbol
        push!(names, arg)
        return :nothing
    elseif arg isa Expr && (arg.head == :(=) || arg.head in _SA_UPDATING_OPERATORS) && arg.args[1] isa Symbol
        push!(names, arg.args[1])
        return Expr(:block, Expr(arg.head, arg.args[1], _sa_rewrite_updates!(arg.args[2], names)), :nothing)
    elseif arg isa Expr && arg.head == :tuple
        foreach(a -> _sa_rewrite_update!(a, names), arg.args)
        return :nothing
    elseif arg isa Expr && arg.head == :block
        rewritten = [_sa_rewrite_update!(a, names) for a in arg.args if !(a isa LineNumberNode)]
        return Expr(:block, rewritten..., :nothing)
    end
    error("`@update` updates an argument by name: `@update x`, `@update x = v`, `@update x, y`. Got `$arg`.")
end

"""The body with every `return v` written as `return StepReturn(v, updates)` (`updates_expr` builds the updates)."""
function _sa_wrap_returns(ex, updates_expr)
    ex isa Expr || return ex
    _sa_is_opaque(ex) && return ex
    if ex.head == :return
        value = isempty(ex.args) ? nothing : ex.args[1]
        return Expr(:return, :(StatefulAlgorithms.StepReturn($value, $updates_expr)))
    end
    return Expr(ex.head, (_sa_wrap_returns(a, updates_expr) for a in ex.args)...)
end

"""The names of the named tuples a body returns literally (`return (; a, b = x)`, or its last expression)."""
function _sa_collect_returned_names(body)
    names = Symbol[]
    namedtuple_names(v) = v isa Expr && v.head == :tuple && !isempty(v.args) && v.args[1] isa Expr && v.args[1].head == :parameters ?
        [a isa Symbol ? a : a.args[1] for a in v.args[1].args if a isa Symbol || (a isa Expr && a.head in (:kw, :(=)) && a.args[1] isa Symbol)] :
        v isa Expr && v.head == :tuple ? [a.args[1] for a in v.args if a isa Expr && a.head == :(=) && a.args[1] isa Symbol] : Symbol[]
    walk(ex) = if ex isa Expr && !_sa_is_opaque(ex)
        ex.head == :return && !isempty(ex.args) && append!(names, namedtuple_names(ex.args[1]))
        foreach(walk, ex.args)
    end
    walk(body)
    statements = body isa Expr && body.head == :block ? [a for a in body.args if !(a isa LineNumberNode)] : Any[body]
    isempty(statements) || append!(names, namedtuple_names(last(statements)))
    return unique(names)
end

"""
Build a `@StepAlgorithm` body as a step: its `@update`s rewritten as plain Julia, and every return (a `return`, or the value of its last
expression) a `StepReturn` of the returned value and the updated names. Returns the body and the updated names.
"""
function _sa_build_step_body(body, fname, signature)
    names = Symbol[]
    rewritten = _sa_rewrite_updates!(body, names)
    names = unique(names)
    arguments = Set{Symbol}(vcat(getproperty.(signature.positional, :name), getproperty.(signature.normal_kwargs, :name)))
    for name in names
        name in arguments || error("`@update $name` in `$fname`: only an argument of the algorithm can be updated (a positional argument, `@managed`, or a keyword).")
    end
    stale = [name for name in _sa_collect_returned_names(body) if name in arguments && !(name in names)]
    isempty(stale) || @warn "`$fname` returns $(join(("`$n`" for n in stale), ", ")), which is also an argument. A return is a value: it no longer writes `$(first(stale))` back. Write `@update $(first(stale))` to update it."
    updates_expr = :(StatefulAlgorithms.StateUpdates($(Expr(:tuple, Expr(:parameters, names...)))))
    wrapped = _sa_wrap_returns(rewritten, updates_expr)
    return Expr(:return, :(StatefulAlgorithms.StepReturn($(Expr(:block, wrapped)), $updates_expr))), Tuple(names)
end

"""The code `@StepAlgorithm` expands to (`legacy = true`: `@StepAlgorithm_legacy`, whose returns are written back)."""
function _step_algorithm_macro(ex; legacy::Bool = false)
    function_ex, outer_config_fields, force_inline = _sa_split_definition(ex)
    function_ex, supertype = _sa_split_supertype(function_ex)
    signature = _sa_parse_signature(function_ex.args[1])
    body = function_ex.args[2]
    config_fields = vcat(outer_config_fields, signature.config_fields)

    fname = signature.fname
    body_name = gensym(Symbol(fname, :_impl))
    init_temps = Dict(field.name => gensym(Symbol(field.name, :_init)) for field in signature.init_fields)
    direct_scope_names = Symbol[
        (getproperty.(signature.positional, :name))...,
        (getproperty.(signature.normal_kwargs, :name))...,
        (getproperty.(config_fields, :name))...,
    ]
    length(unique(direct_scope_names)) == length(direct_scope_names) || error("Duplicate names are not allowed in @StepAlgorithm: $(direct_scope_names)")
    config_init_overlap = intersect(Set(getproperty.(config_fields, :name)), Set(getproperty.(signature.init_fields, :name)))
    isempty(config_init_overlap) || error("@config names cannot overlap with @init names: $(collect(config_init_overlap))")

    positional_bindings = [_sa_build_binding(arg.name, arg.typeexpr) for arg in signature.positional]
    plain_pos_bindings = [_sa_build_binding(arg.name, arg.typeexpr) for arg in signature.plain_pos]
    kw_bindings = [Expr(:kw, _sa_build_binding(kw.name, kw.typeexpr), kw.default) for kw in signature.normal_kwargs]

    body_signature = Expr(:call, body_name, Expr(:(::), :_algo, fname), positional_bindings...)
    if !isempty(kw_bindings)
        insert!(body_signature.args, 2, Expr(:parameters, kw_bindings...))
    end
    body_signature = _sa_rewrap_where(body_signature, signature.where_params)

    config_assignments = _sa_bind_config_fields(config_fields, :_algo)
    # A step returns a `StepReturn`: its return value and its `@update`s (a legacy step returns what its body returns).
    if legacy
        _sa_rewrite_updates!(body, Symbol[]) == body || error("`@update` is not available in `@StepAlgorithm_legacy`; use `@StepAlgorithm`.")
        updated = ()
    else
        body, updated = _sa_build_step_body(body, fname, signature)
    end
    body_method = Expr(:function, body_signature, Expr(:block, config_assignments..., body))
    # By default Julia decides whether to inline the body. `@inline` on the definition forces it
    # into the plan's step, which pays off for medium-sized hot kernels (see the docstring).
    force_inline && (body_method = Expr(:macrocall, Expr(:., :Base, QuoteNode(Symbol("@inline"))), nothing, body_method))

    # Direct calls, `step!(Name(), args...)`, return the step's value. With `@managed` arguments there are two:
    # one is passed the state's values, the other its `@init` values and builds the state first.
    kw_forward = [Expr(:kw, kw.name, kw.name) for kw in signature.normal_kwargs]
    positional_names = [arg.name for arg in signature.positional]
    init_error = isempty(signature.managed_pos) ?
        :(isnothing(_init) || isempty(_init) || error("Cannot pass @init values to $(string($fname)) without any @managed arguments")) :
        :(isnothing(_init) || error("Cannot pass both managed positional arguments and @init values to $(string($fname))"))
    direct_methods = Any[Expr(:function, _sa_build_direct_signature(fname, positional_bindings, kw_bindings, nothing, signature.where_params), quote
            $init_error
            return StatefulAlgorithms.step_value($body_name(_algo, $(positional_names...); $(kw_forward...)))
        end)]
    if !isempty(signature.managed_pos)
        # An `@init` value with the name of a plain argument or keyword is only read into its hidden temp: the body sees the argument.
        argument_names = Set{Symbol}(vcat([arg.name for arg in signature.plain_pos], [kw.name for kw in signature.normal_kwargs]))
        visible_init_names = Set(field.name for field in signature.init_fields if !(field.name in argument_names))
        init_assignments = _sa_bind_init_fields(signature.init_fields, :_init, init_temps; visible_names = visible_init_names)
        managed_assignments = [_sa_bind_managed_field(field, init_temps, :_init) for field in signature.managed_pos]
        call_args = vcat([arg.name for arg in signature.plain_pos], [arg.name for arg in signature.managed_pos])
        init_default = Expr(:tuple, Expr(:parameters))
        push!(direct_methods, Expr(:function, _sa_build_direct_signature(fname, plain_pos_bindings, kw_bindings, init_default, signature.where_params), quote
                $(config_assignments...)
                $(init_assignments...)
                $(managed_assignments...)
                return StatefulAlgorithms.step_value($body_name(_algo, $(call_args...); $(kw_forward...)))
            end))
    end

    init_assignments = _sa_bind_init_fields(signature.init_fields, :context, init_temps)
    managed_assignments = [_sa_bind_managed_field(field, init_temps, :context) for field in signature.managed_pos]
    managed_tuple_expr = Expr(:tuple, Expr(:parameters, [Expr(:kw, field.name, field.name) for field in signature.managed_pos]...))
    init_method = quote
        function StatefulAlgorithms.init(_algo::$fname, context::C) where {C <: Union{StatefulAlgorithms.AbstractContext, NamedTuple}}
            $(config_assignments...)
            $(init_assignments...)
            $(managed_assignments...)
            return $managed_tuple_expr
        end
    end

    step_pos_assignments = [_sa_bind_runtime_positional(field, :context) for field in signature.positional]
    step_kw_assignments = [_sa_bind_runtime_keyword(field, :context) for field in signature.normal_kwargs]
    positional_name_tuple = Expr(:tuple, QuoteNode.(positional_names)...)
    metadata_methods = quote
        StatefulAlgorithms._dsl_step_positional_names(::$fname) = $positional_name_tuple
        StatefulAlgorithms._dsl_step_positional_names(::Type{<:$fname}) = $positional_name_tuple
        StatefulAlgorithms.updated_names(::Type{<:$fname}) = $(Expr(:tuple, QuoteNode.(updated)...))
    end
    context_step_method = quote
        function StatefulAlgorithms.step!(_algo::$fname, context::C) where {C <: Union{StatefulAlgorithms.AbstractContext, NamedTuple}}
            $(step_pos_assignments...)
            $(step_kw_assignments...)
            return $body_name(_algo, $(positional_names...); $(kw_forward...))
        end
    end

    struct_expr = if isempty(config_fields)
        :(Base.@__doc__ struct $fname <: $supertype end)
    else
        # A field without a declared type is stored with a type parameter (`x::T_x`, `T_x <: S` for `x <: S`), so its
        # value keeps its type; a field with a declared type (`x::T`) has exactly that type.
        typeparams = Any[]
        field_exprs = map(config_fields) do field
            isnothing(field.typeexpr) || return Expr(:(=), Expr(:(::), field.name, field.typeexpr), field.default)
            P = _sa_config_typeparam_name(field.name)
            push!(typeparams, isnothing(field.bound) ? P : Expr(:(<:), P, field.bound))
            return Expr(:(=), Expr(:(::), field.name, P), field.default)
        end
        struct_name = isempty(typeparams) ? fname : Expr(:curly, fname, typeparams...)
        :(Base.@__doc__ Base.@kwdef struct $struct_name <: $supertype
            $(field_exprs...)
        end)
    end

    q = quote
        $struct_expr
        $body_method
        $(direct_methods...)
        $init_method
        $context_step_method
        $metadata_methods
    end
    return esc(q)
end

"""
Build the signature of a direct `step!(Name(), args...; kwargs..., _init = init_default)` method, with the definition's
`where` parameters.
"""
function _sa_build_direct_signature(fname, positional_bindings, kw_bindings, init_default, where_params)
    signature = Expr(:call, :(StatefulAlgorithms.step!), Expr(:parameters, kw_bindings..., Expr(:kw, :_init, init_default)),
        Expr(:(::), :_algo, fname), positional_bindings...)
    return _sa_rewrap_where(signature, where_params)
end

"""
    _sa_split_supertype(function_ex) -> (function_ex, supertype)

`function F(...) <: T` parses as a function whose body starts with the statement `<:T`; take that statement out and
return `T` as the supertype of the generated struct. Without it the supertype is `StepAlgorithm`.
"""
function _sa_split_supertype(function_ex)
    body = function_ex.args[2]
    idx = findfirst(stmt -> !(stmt isa LineNumberNode), body.args)
    stmt = idx === nothing ? nothing : body.args[idx]
    if stmt isa Expr && stmt.head == :<: && length(stmt.args) == 1
        newbody = Expr(:block, body.args[1:idx-1]..., body.args[idx+1:end]...)
        return Expr(:function, function_ex.args[1], newbody), only(stmt.args)
    end
    return function_ex, :(StatefulAlgorithms.StepAlgorithm)
end

"""
    @StepAlgorithm function Name(...)
        ...
    end

Define a `StepAlgorithm` from a function-like signature.

The macro splits the signature into four groups:

1. Plain positional arguments:
   Runtime values read from the process context during `StatefulAlgorithms.step!`.
2. `@managed(...)` positional arguments:
   Local algorithm state created during `StatefulAlgorithms.init` and then read back from the
   algorithm's own subcontext during `StatefulAlgorithms.step!`.
3. Normal keyword arguments:
   Runtime keyword-style values looked up from the context during `StatefulAlgorithms.step!`, with
   the declared default used when the key is missing.
4. `@config ...` declarations:
   Struct fields placed on the generated algorithm type with default values.

An optional trailing `@init((; ...))` declares init values: values used only to build the `@managed` state, while
`StatefulAlgorithms.init` runs (or a direct `step!(Name(), args...; @init((; ...)))` builds the state first). A step
does not see them unless a `@managed` argument keeps them. (`@inputs` and `@input` are deprecated aliases of `@init`.)

# Supported signature forms

The macro accepts normal function signatures and `where` signatures:

```julia
@StepAlgorithm function Accumulate(x)
    @update x = x + 1
end

@StepAlgorithm function resetgraph!(isinggraph::G) where G
    resetstate!(isinggraph)
    return
end
```

# Returns and updates

The body is a Julia function body: `return v` (or its last expression) is the step's return value, which a block
captures with `y = Name(...)`. Assigning an argument only changes the body's local copy. `@update x` (or
`@update x = v`, `@update x += v`, `@update x, y`) writes `x`'s value at the `return` back to where the algorithm read
it: its `@managed` state, or the variable of the block passed as `x`. A body ending in `@update` returns `nothing`.
In a plan the generated `step!(algo, context)` returns a `StepReturn` of the value and the updates;
`updated_names(Name)` lists the updated names.

# Positional parsing rules

Plain positional arguments:

```julia
@StepAlgorithm function F(a, b)
    ...
end
```

These are treated as runtime values and are looked up from the context inside `StatefulAlgorithms.step!`.

Managed positional arguments:

```julia
@StepAlgorithm function F(
    a,
    @managed(state = 0.0),
    @managed(cache),
    @managed(buffer = zeros(n), metric = 0.0);
    @init((; n = 8))
)
    ...
end
```

The managed forms mean:

- `@managed(name)`:
  create a managed local called `name` by reading `name` from the init context.
- `@managed(name = expr)`:
  create a managed local called `name` by evaluating `expr` during `StatefulAlgorithms.init`.
- `@managed(a, b = expr, c = expr2)`:
  expand to multiple managed locals in the written order.

Managed initializer expressions run during `StatefulAlgorithms.init`, so they may refer to:

- init values declared by `@init`
- earlier managed locals in the same generated init block
- plain Julia globals/functions in scope

They do not read plain runtime positional arguments from `step!`.

# Keyword parsing rules

Regular keyword arguments:

```julia
@StepAlgorithm function F(a; gain = 1.0, offset::Float64 = 0.0)
    ...
end
```

These are runtime keyword-style values. During `StatefulAlgorithms.step!`, the macro reads them from the
context with `get(context, :name, default)`.

Init values:

```julia
@StepAlgorithm function F(
    a,
    @managed(scale = scale0);
    gain = 1.0,
    @init((; scale0::Float64 = 2.0, n::Int))
)
    ...
end
```

Rules:

- only one `@init` is allowed
- it must be the last keyword-like entry in the signature
- entries may be required (`n`) or defaulted (`scale0 = 2.0`)

Config block:

```julia
@StepAlgorithm begin
    @config seed::Int = 3
    @config begin
        n::Int = 4
    end
    function F(
        x,
        @managed(buffer = fill(seed, n));
        gain = 1.0,
        @init((;))
    )
        return (; total = sum(buffer) + seed + n + gain + x)
    end
end
```

Rules:

- every `@config` field must have a default
- config values become fields on the generated algorithm struct, always typed:
  - `name = value`: the field's type is a type parameter of the struct, the type of the value
    (`struct F{T_name}; name::T_name; end`)
  - `name <: S = value`: the same, with the type parameter bounded (`T_name <: S`)
  - `name::T = value`: the field has exactly the type `T`
- `@config` may be written in the surrounding block form or as a prelude like
  `@StepAlgorithm @config seed = 1 function F(...) ... end`
- config field names are available directly as locals inside the algorithm body
  and in generated `init`/direct-context `step!`; use `seed`, not `config.seed`

# What the macro defines

For a declaration like:

```julia
@StepAlgorithm function MyAlgo(...)
    body
end
```

the macro generates:

- `struct MyAlgo <: StatefulAlgorithms.StepAlgorithm end`, or `Base.@kwdef struct MyAlgo ... end`
  when `@config` fields are declared
- a hidden implementation function that contains `body`
- `StatefulAlgorithms.step!(algo::MyAlgo, ...)` methods for direct calls
- `StatefulAlgorithms.init(::MyAlgo, context)` to build the managed local subcontext
- `StatefulAlgorithms.step!(::MyAlgo, context)` to read runtime values and call the hidden implementation

# User entrypoints

There are three main ways users interact with a macro-generated algorithm:

1. Direct call:

```julia
step!(MyAlgo(), a; @init((; n = 4)))     # builds the `@managed` state from the init values, then steps
step!(MyAlgo(), a, state_values...)      # is passed the `@managed` values
```

Both return the step's value. The macro does not define a same-name Julia function, so normal struct
constructors remain untouched.

2. Process init hook:

```julia
StatefulAlgorithms.init(MyAlgo(), context)
```

This reads the declared init values from `context` and returns the `@managed` state as a named tuple.

3. Process step hook:

```julia
StatefulAlgorithms.step!(MyAlgo(), context)
```

This reads plain positional and runtime keyword arguments from `context`, reads managed values
from the algorithm subcontext, and forwards everything to the generated implementation.

# Supertype

`<: T` after the signature makes the generated struct a subtype of `T` instead of `StepAlgorithm`; `T` must itself
be a `StepAlgorithm`. With a `where` clause, write its parameters in braces (`where {S} <: T`): `where S <: T` is a
bound on `S`.

```julia
@StepAlgorithm function Metropolis(spins, T, @managed(rng = Xoshiro(1))) <: MonteCarloAlgorithm
    # ...
end
```

# Inlining the body

The plan always inlines the small generated `step!` that reads the declared values. The user's
body is a separate function, so Julia decides whether to inline it. That is the right default:
small bodies are inlined anyway, and a large body that is not inlined is compiled once and reused
by every plan that contains it. A medium-sized hot kernel (a few nanoseconds per step, e.g. a
single-spin Metropolis update) can be too big for Julia's size-based heuristic, and then the call
itself costs about 1 ns per step. Put `@inline` on the function to force the body into the plan:

```julia
@StepAlgorithm @inline function Metropolis(spins, T, @managed(rng = Xoshiro(1)))
    # ...
end
```

`@inline` also works after `@config` and inside the block form. The trade-off is compile time:
a forced body is compiled again inside every plan that uses it.

# Type annotations and `where`

Argument type annotations and `where` clauses are kept on the generated direct `step!` methods and on the
hidden function that holds the body. The generated `StatefulAlgorithms.init(algo, context)` and
`StatefulAlgorithms.step!(algo, context)` read the values from the context into untyped locals and pass them to that
function, so its annotations check them.
"""
macro StepAlgorithm(ex)
    return _step_algorithm_macro(ex)
end

"""Deprecated compatibility alias for [`@StepAlgorithm`](@ref)."""
macro ProcessAlgorithm(ex)
    @warn "`@ProcessAlgorithm` is deprecated; use `@StepAlgorithm` instead." maxlog = 1
    return _step_algorithm_macro(ex)
end

export @StepAlgorithm, @ProcessAlgorithm, @init, @input, @inputs, @update
