#=
Declared locals in a DSL block, written as in Julia:

    local x            # no value yet; its type is the type of what is written to it
    local x::Float64   # a type, no value yet
    local x = x0       # a value: a literal or an outside name, taken where the block is built
    local x = f()      # a local, assigned by the step `x = f()` where it is written

Each lowers to a `Local` on the block (a declared local of its scope, see `Scope`): it lives for the run and is kept on
a pause. Statements read it by name and write it by assigning it (`x = f(x)`).

Without `local`, an assignment is a step, as in a Julia loop body: `x = 0.0` assigns 0.0 to `x` every time it runs,
like `x = f()`; the value lasts one step of its block. A literal on the right is the call `identity(0.0)`, an array
literal or interpolated string a call too (`[0, 0]` is `Base.vect(0, 0)`), and `x::T = v` is `x = convert(T, v)`.
A bare name (`x = Algo`) is an algorithm entry. Reading a local declared without a value before anything is written
to it is an error.
=#

"""Whether `rhs` is a literal: a number, string, char, quoted symbol, `nothing`, or a tuple of those."""
_dsl_is_literal(rhs) = rhs isa Number || rhs isa AbstractString || rhs isa Char || rhs isa QuoteNode || rhs === :nothing
_dsl_is_literal(rhs::Expr) = rhs.head == :tuple && all(_dsl_is_literal, rhs.args)

"""Whether `value` in `local x = value` is a step (a call, a macro, an array literal, an interpolated string), assigned where it is written."""
_dsl_is_step_value(value) = value isa Expr && value.head in (:call, :macrocall, :vect, :vcat, :hcat, :ncat, :string, :comprehension)

"""
`stmt` as a step when it is an assignment: its right-hand side as a call (see `_dsl_as_call`), and `x::T = v` as
`x = convert(T, v)`. Anything else as it is.
"""
function _dsl_assignment_as_call(stmt)
    stmt isa Expr && stmt.head == :(=) || return stmt
    lhs, rhs = stmt.args[1], _dsl_as_call(stmt.args[2])
    if lhs isa Expr && lhs.head == :(::) && length(lhs.args) == 2 && lhs.args[1] isa Symbol
        lhs, rhs = lhs.args[1], Expr(:call, Expr(:., :Base, QuoteNode(:convert)), lhs.args[2], rhs)
    end
    return Expr(:(=), lhs, rhs)
end

"""
`rhs` as a call when it is a literal (`identity(0.0)`), an array literal or an interpolated string (`[a, b]` is
`Base.vect(a, b)`), else as it is.
"""
function _dsl_as_call(rhs)
    _dsl_is_literal(rhs) && return Expr(:call, Expr(:., :Base, QuoteNode(:identity)), rhs)
    rhs isa Expr || return rhs
    f = get((; vect = :vect, vcat = :vcat, hcat = :hcat, string = :string), rhs.head, nothing)
    isnothing(f) && return rhs
    return Expr(:call, Expr(:., :Base, QuoteNode(f)), rhs.args...)
end

"""
The locals a block statement declares, as `(; declarations, steps)`, or `nothing` when `stmt` is not a declaration
(see the note above). `declarations` are `(name, type expression or nothing, value expression or nothing)` tuples;
`steps` are the assignments `local x = f()` adds after declaring `x`. `taken` are the names the block already has.
"""
function _dsl_parse_local_declaration(stmt, taken::Set{Symbol})
    if stmt isa Expr && stmt.head == :local
        targets = length(stmt.args) == 1 && stmt.args[1] isa Expr && stmt.args[1].head == :tuple ? stmt.args[1].args : stmt.args
        declarations = [_dsl_local_target(target, taken) for target in targets]
        steps = [:($name = $value) for (name, _, value) in declarations if _dsl_is_step_value(value)]
        declarations = [(name, type, _dsl_is_step_value(value) ? nothing : value) for (name, type, value) in declarations]
        return (; declarations, steps)
    end
    return nothing
end

"""
An error for `x = y` where `y` is a value of the block (a state field, an input, a local or an earlier statement's
result): a block's statements are steps, and a bare name is not one. Without this, `y` would be read as an algorithm
entry. An `@alias` name on the right (`x = alias`) is an algorithm entry and stays allowed.
"""
function _dsl_reject_name_assignment(stmt, known::Set{Symbol}, alias_map, line)
    stmt isa Expr && stmt.head == :(=) && stmt.args[2] isa Symbol || return nothing
    name = stmt.args[2]
    name in known && !haskey(alias_map, name) || return nothing
    at = isnothing(line) ? "" : " ($(line.file):$(line.line))"
    error("`$(stmt)` assigns the block's value `$name` to `$(stmt.args[1])`$at. A statement in a block is a step: a call, ",
          "an algorithm or a declaration. Read `$name` where it is needed, or copy it with a call (`$(stmt.args[1]) = copy($name)`).")
end

"""One declared local of a `local` statement: `x`, `x::T`, `x = v` or `x::T = v`."""
function _dsl_local_target(target, taken::Set{Symbol})
    value = nothing
    if target isa Expr && target.head == :(=)
        target, value = target.args[1], target.args[2]
    end
    type = nothing
    if target isa Expr && target.head == :(::) && length(target.args) == 2
        target, type = target.args[1], target.args[2]
    end
    target isa Symbol || error("Cannot declare `$(target)` as a local in a DSL block; declare a name: `local x`, `local x::T`, `local x = value`.")
    target in taken && error("`$target` is declared as a local, but the block already has a `$target` (a state field, an input or an earlier statement's result). Declare it once, before it is used.")
    return (target, type, value)
end

"""The code a declaration adds to the block: a `Local` for each declared name (see `_composite_dsl_declare_local!`)."""
function _dsl_local_declaration_expr(declarations)
    exprs = map(declarations) do (name, type, value)
        value_expr = isnothing(value) ? :undef : esc(value)
        type_expr = isnothing(type) ? :nothing : esc(type)
        :(StatefulAlgorithms._composite_dsl_declare_local!(_dsl_options, _dsl_producers, $(QuoteNode(name)), $value_expr, $type_expr))
    end
    return Expr(:block, exprs...)
end

"""
Declare the local `name` on the block being built: a `Local` in its options, and `name` recorded as read from the
declared locals by the statements after it. `value` is `undef` for none; `type` is `nothing` for none.
"""
function _composite_dsl_declare_local!(options::Vector{Any}, producers::Dict{Symbol, Any}, name::Symbol, value, type)
    @nospecialize value type
    push!(options, Local(NamedTuple{(name,), Tuple{_dsl_local_storage_type(value, type)}}((_dsl_local_initial(value, type),))))
    producers[name] = :_declared_locals
    return options
end

_dsl_local_storage_type(value, ::Nothing) = typeof(value)
_dsl_local_storage_type(::UndefInitializer, ::Type{T}) where {T} = maybe_type(T, UndefInitializer)
_dsl_local_storage_type(value, ::Type{T}) where {T} = T
_dsl_local_initial(value, ::Nothing) = value
_dsl_local_initial(::UndefInitializer, ::Type{T}) where {T} = maybe_type(T, UndefInitializer)()
_dsl_local_initial(value, ::Type{T}) where {T} = convert(T, value)

"""Give a nested block the names of its enclosing blocks (`names`): each is read from the same producer as outside (`outer`)."""
function _composite_dsl_inherit_names!(producers::Dict{Symbol, Any}, outer::Dict{Symbol, Any}, names::Tuple)
    foreach(name -> haskey(outer, name) && (producers[name] = outer[name]), names)
    return producers
end

"""Whether a DSL producer reads by name from the scope (a declared local or a captured return): those need no wire into a call."""
_dsl_read_by_name(owner) = false
_dsl_read_by_name(owner::Symbol) = _is_scope_part(context_part(Val(owner)))
_is_scope_part(::Union{CapturedReturns, DeclaredLocals}) = true
_is_scope_part(::ContextPart) = false

"""Whether a DSL producer is the declared locals (a name declared with `local`)."""
_dsl_is_declared(owner) = false
_dsl_is_declared(owner::Symbol) = context_part(Val(owner)) isa DeclaredLocals
