"""
Strip DSL-only wrappers from the right-hand side of `@context`.

`@context` names the underlying algorithm expression, not its schedule wrapper,
so forms like `@context c = plus()`, `@context c = @repeat 2 plus()`, and
`@context c = @interval 3 plus()` all bind `c` to the same underlying `plus`
expression.
"""
function _dsl_normalize_context_binding(ex)
    if ex isa Expr
        if ex.head == :call && length(ex.args) == 1
            return _dsl_normalize_context_binding(ex.args[1])
        elseif ex.head == :macrocall && ex.args[1] in (Symbol("@repeat"), Symbol("@every"), Symbol("@interval"))
            length(ex.args) == 4 || error("Scheduling wrappers inside `@context` must use `@repeat n expr`, `@every n expr`, or `@interval n expr`.")
            return _dsl_normalize_context_binding(ex.args[4])
        end
    end
    return ex
end

"""
Parse one `@context name = algo()` declaration.

The right-hand side is normalized by stripping empty call syntax and any outer
DSL scheduling wrapper before the alias is recorded.
"""
function _dsl_parse_context(stmt)
    stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@context") || error("Invalid @context statement `$stmt`.")
    length(stmt.args) == 3 || error("@context expects a single assignment like `@context c = plus()`.")
    assign = stmt.args[3]
    assign isa Expr && assign.head == :(=) || error("@context expects a single assignment like `@context c = plus()`.")
    lhs = assign.args[1]
    lhs isa Symbol || error("@context names must be symbols. Got `$lhs`.")
    return lhs => _dsl_normalize_context_binding(assign.args[2])
end

"""Rewrite the root of a dotted/ref expression if it starts from a context alias."""
function _dsl_rewrite_context_root(context_map, ex)
    if ex isa Symbol
        return get(context_map, ex, ex), haskey(context_map, ex)
    elseif ex isa Expr && ex.head == :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
        rewritten_base, changed = _dsl_rewrite_context_root(context_map, ex.args[1])
        return changed ? Expr(:., rewritten_base, ex.args[2]) : ex, changed
    elseif ex isa Expr && ex.head == :ref && !isempty(ex.args)
        rewritten_base, changed = _dsl_rewrite_context_root(context_map, ex.args[1])
        return changed ? Expr(:ref, rewritten_base, ex.args[2:end]...) : ex, changed
    end
    return ex, false
end

"""Extract a lowered route owner/source pair from a `@context` reference."""
function _dsl_parse_context_route_expr(context_map, ex)
    if ex isa Expr && ex.head == :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
        source = ex.args[2].value
        source isa Symbol || return nothing
        if ex.args[1] isa Symbol && haskey(context_map, ex.args[1])
            owner = Expr(:., context_map[ex.args[1]], QuoteNode(:_state))
            return (; owner, source)
        end
        owner, changed = _dsl_rewrite_context_root(context_map, ex.args[1])
        return changed ? (; owner, source) : nothing
    end
    return nothing
end

"""Rewrite the root of a dotted/ref expression if it starts from a known alias."""
function _dsl_rewrite_alias_owner_root(alias_map, ex)
    if ex isa Symbol
        binding = _dsl_alias_binding(alias_map, ex)
        isnothing(binding) && return ex, false
        return _dsl_known_owner_expr(binding.value, binding.name), true
    elseif ex isa Expr && ex.head == :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
        rewritten_base, changed = _dsl_rewrite_alias_owner_root(alias_map, ex.args[1])
        return changed ? Expr(:., rewritten_base, ex.args[2]) : ex, changed
    elseif ex isa Expr && ex.head == :ref && !isempty(ex.args)
        rewritten_base, changed = _dsl_rewrite_alias_owner_root(alias_map, ex.args[1])
        return changed ? Expr(:ref, rewritten_base, ex.args[2:end]...) : ex, changed
    end
    return ex, false
end

"""Extract a lowered route owner/source pair from a known alias field reference."""
function _dsl_parse_alias_route_expr(alias_map, ex)
    if ex isa Expr && ex.head == :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
        source = ex.args[2].value
        source isa Symbol || return nothing
        owner, changed = _dsl_rewrite_alias_owner_root(alias_map, ex.args[1])
        return changed ? (; owner, source) : nothing
    end
    return nothing
end

"""Extract a lowered route owner/source pair from a known alias or `@context` field reference."""
function _dsl_parse_owned_route_expr(alias_map, context_map, ex)
    parsed = _dsl_parse_context_route_expr(context_map, ex)
    isnothing(parsed) || return parsed
    return _dsl_parse_alias_route_expr(alias_map, ex)
end

"""
Extract a route from a symbol alias that names an owned field.

This lets declarations like `@alias model = dynamics.model` behave like the
field reference itself in later route positions, without requiring `model` to be
returned by any preceding DSL statement.
"""
function _dsl_parse_symbol_alias_route_expr(alias_map::Dict{Symbol, Any}, context_map::Dict{Symbol, Any}, name::Symbol)
    binding = _dsl_alias_binding(alias_map, name)
    isnothing(binding) && return nothing

    # Only aliases to owned-field expressions define routes here. Plain aliases
    # such as `@alias dynamics = algo` still flow through the normal entry path.
    return _dsl_parse_owned_route_expr(alias_map, context_map, binding.value)
end

"""Strip line metadata from expressions before keeping them for user-facing display."""
function _dsl_display_expr(ex)
    ex isa Expr || return ex
    return Base.remove_linenums!(deepcopy(ex))
end

"""Remove line metadata from this generated DSL implementation file only."""
function _dsl_strip_generated_linenums!(ex)
    ex isa Expr || return ex
    generated_file = Symbol(@__FILE__)
    filter!(ex.args) do arg
        !(arg isa LineNumberNode && arg.file == generated_file)
    end
    for arg in ex.args
        _dsl_strip_generated_linenums!(arg)
    end
    return ex
end

"""Parse explicit `@transform(f, source)` syntax used in route positions."""
function _dsl_parse_transform_expr(ex)
    ex isa Expr && ex.head == :macrocall && ex.args[1] == Symbol("@transform") || return nothing
    length(ex.args) == 4 || error("@transform expects exactly two arguments like `@transform(x -> x * 2, produced)`.")
    return (; transform_expr = ex.args[3], source_expr = ex.args[4], display = _dsl_display_expr(ex))
end

"""Parse one explicit transformed route source."""
function _dsl_parse_explicit_transform_input(alias_map, context_map, ex, destination::Symbol)
    parsed = _dsl_parse_transform_expr(ex)
    isnothing(parsed) && return nothing

    source_expr = parsed.source_expr
    if source_expr isa Symbol
        owned_route = _dsl_parse_symbol_alias_route_expr(alias_map, context_map, source_expr)
        if !isnothing(owned_route)
            return (; kind = :context_transform, owner = owned_route.owner, source = owned_route.source, destination, transform_expr = parsed.transform_expr, display = parsed.display)
        end
        return (; kind = :simple_transform, source = source_expr, destination, transform_expr = parsed.transform_expr, display = parsed.display)
    end

    owned_route = _dsl_parse_owned_route_expr(alias_map, context_map, source_expr)
    !isnothing(owned_route) || error("@transform source must be a routable symbol or owned field reference like `produced`, `dynamics.state`, or `c1.plus_capture.captured`. Got `$source_expr`.")
    return (; kind = :context_transform, owner = owned_route.owner, source = owned_route.source, destination, transform_expr = parsed.transform_expr, display = parsed.display)
end
