#=
Declared locals in a DSL block, written as in Julia:

    local x            # no value yet; its type is the type of what is written to it
    local x::Float64   # a type, no value yet

Each lowers to a `Local` on the block (a declared local of its scope, see `Scope`): it lives for the run and is kept on
a pause. Statements read it by name and write it by assigning it (`x = f(x)`). A declaration has no value
(`local x = 0.0` is an error): a value that starts somewhere and is kept between steps is state (`@state x = 0.0`).
Reading a local before anything is written to it is an error.

Without `local`, an assignment is a step, as in a Julia loop body: `x = 0.0` assigns 0.0 to `x` every time it runs,
like `x = f()`; the value lasts one step of its block. A literal on the right is the call `identity(0.0)`, an array
literal or interpolated string a call too (`[0, 0]` is `Base.vect(0, 0)`), and `x::T = v` is `x = convert(T, v)`.
A bare name (`x = Algo`) is an algorithm entry.

An assignment on a schedule (`y = @every 2 f()`) does not run in every step, so it may only write a name the block
already has: a declared local (`local y` before it), or a name assigned or declared earlier. Otherwise building the
block is an error.
=#

"""Whether `rhs` is a literal: a number, string, char, quoted symbol, `nothing`, or a tuple of those."""
_dsl_is_literal(rhs) = rhs isa Number || rhs isa AbstractString || rhs isa Char || rhs isa QuoteNode || rhs === :nothing
_dsl_is_literal(rhs::Expr) = rhs.head == :tuple && all(_dsl_is_literal, rhs.args)

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
The locals a block statement declares, as `(name, type expression or nothing)` tuples, or `nothing` when `stmt` is not
a declaration (see the note above). `taken` are the names the block already has.
"""
function _dsl_parse_local_declaration(stmt, taken::Set{Symbol})
    if stmt isa Expr && stmt.head == :local
        targets = length(stmt.args) == 1 && stmt.args[1] isa Expr && stmt.args[1].head == :tuple ? stmt.args[1].args : stmt.args
        return [_dsl_local_target(target, taken) for target in targets]
    end
    return nothing
end

"""
An error for an assignment on a schedule (`y = @every 2 f()`, `y = @interval n f()`) to a name the block does not
have yet (`known`): it does not run in every step, so `y` would have no value in the others. Declare it first,
`local y`. `@every 1` runs in every step and is allowed.
"""
function _dsl_reject_undeclared_scheduled_assignment(stmt, known::Set{Symbol}, line)
    stmt isa Expr && stmt.head == :(=) || return nothing
    rhs = stmt.args[2]
    rhs isa Expr && rhs.head == :macrocall && rhs.args[1] in (Symbol("@every"), Symbol("@interval")) || return nothing
    interval = filter(a -> !(a isa LineNumberNode), rhs.args[2:end])
    !isempty(interval) && first(interval) == 1 && return nothing
    lhs = stmt.args[1]
    lhs isa Expr && lhs.head == :(::) && (lhs = lhs.args[1])
    names = _dsl_try_parse_output_symbols(lhs)
    isnothing(names) && return nothing
    undeclared = filter(name -> !(name in known), collect(names))
    isempty(undeclared) && return nothing
    at = isnothing(line) ? "" : " ($(line.file):$(line.line))"
    error("`$(stmt)` assigns ", join(("`$n`" for n in undeclared), ", "), " on a schedule$at: it does not run in every step, ",
          "so the name has no value in the others. Declare it first: ", join(("`local $n`" for n in undeclared), ", "), ".")
end

"""
`x = @repeat spec f()` in a routine as `(; declare, block)`: the repeated block `@repeat spec begin x = f() end`, and
the names it assigns that `known` (the names the block has) does not have yet, to declare before it (`local x`).
`nothing` for any other statement.

Why: the repeats run in a loop, and every name they assign has to exist before it, with its type (it is read after
the repeats, and a stop condition may read it between them), as `x` would be declared before a Julia loop that
assigns it. As a block, the statement's algorithm and the call that captures its return run together in each repeat,
and the algorithm's return is removed when the block ends: every repeat leaves the runtime context with the type it
started with.
"""
function _dsl_repeated_assignment(stmt, known::Set{Symbol})
    stmt isa Expr && stmt.head == :(=) || return nothing
    lhs, rhs = stmt.args
    rhs isa Expr && rhs.head == :macrocall && rhs.args[1] == Symbol("@repeat") || return nothing
    args = filter(a -> !(a isa LineNumberNode), rhs.args[2:end])
    length(args) == 2 || return nothing
    spec, body = args
    body isa Expr && body.head == :block && return nothing          # `x = @repeat n begin ... end`: left as it is
    names = _dsl_try_parse_output_symbols(lhs isa Expr && lhs.head == :(::) ? lhs.args[1] : lhs)
    isnothing(names) && return nothing
    declare = [name for name in names if !(name in known)]
    block = Expr(:macrocall, Symbol("@repeat"), rhs.args[2], spec, Expr(:block, Expr(:(=), lhs, body)))
    return (; declare, block)
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

"""One declared local of a `local` statement, `x` or `x::T`, as `(name, type expression or nothing)`."""
function _dsl_local_target(target, taken::Set{Symbol})
    if target isa Expr && target.head == :(=)
        name = target.args[1] isa Expr && target.args[1].head == :(::) ? target.args[1].args[1] : target.args[1]
        error("`local $(target)`: a local is declared without a value, `local $name`, and written by assigning it (`$name = f()`). ",
              "A value that starts at `$(target.args[2])` and is kept between steps is state: `@state $name = $(target.args[2])`.")
    end
    type = nothing
    if target isa Expr && target.head == :(::) && length(target.args) == 2
        target, type = target.args[1], target.args[2]
    end
    target isa Symbol || error("Cannot declare `$(target)` as a local in a DSL block; declare a name: `local x` or `local x::T`.")
    target in taken && error("`$target` is declared as a local, but the block already has a `$target` (a state field, an input or an earlier statement's result). Declare it once, before it is used.")
    return (target, type)
end

"""The code a declaration adds to the block: a `Local` for each declared name (see `_composite_dsl_declare_local!`)."""
function _dsl_local_declaration_expr(declarations)
    exprs = map(declarations) do (name, type)
        type_expr = isnothing(type) ? :nothing : esc(type)
        :(StatefulAlgorithms._composite_dsl_declare_local!(_dsl_options, _dsl_producers, $(QuoteNode(name)), $type_expr))
    end
    return Expr(:block, exprs...)
end

"""
Declare the local `name` on the block being built: a `Local` without a value in its options, and `name` recorded as
read from the declared locals by the statements after it. `type` is `nothing` when the declaration names none.
"""
function _composite_dsl_declare_local!(options::Vector{Any}, producers::Dict{Symbol, Any}, name::Symbol, type)
    @nospecialize type
    push!(options, isnothing(type) ? Local(name) : Local(name => type))
    producers[name] = :_declared_locals
    return options
end

"""Give a nested block the names of its enclosing blocks (`names`): each is read from the same producer as outside (`outer`)."""
function _composite_dsl_inherit_names!(producers::Dict{Symbol, Any}, outer::Dict{Symbol, Any}, names::Tuple)
    foreach(name -> haskey(outer, name) && (producers[name] = outer[name]), names)
    return producers
end

"""Whether a DSL producer reads by name from the scope (a declared local or a captured return): those need no wire into a call."""
_dsl_read_by_name(owner) = false
_dsl_read_by_name(owner::Symbol) = _is_scoped_runtime_partition(context_partition(Val(owner)))
"""Whether a partition is one of the two runtime context partitions a plan node's scope holds: captured returns and declared locals."""
_is_scoped_runtime_partition(::Union{CapturedReturns, DeclaredLocals}) = true
_is_scoped_runtime_partition(::ContextPartition) = false

"""Whether a DSL producer is the declared locals (a name declared with `local`)."""
_dsl_is_declared(owner) = false
_dsl_is_declared(owner::Symbol) = context_partition(Val(owner)) isa DeclaredLocals

"""
    @mutable y = f()
    @mutable local x

In a DSL block: the names this statement assigns or declares may be changed by an algorithm that updates its argument
(`@update` in `@StepAlgorithm`). It changes nothing else; it only says that this is intended, so building the block
does not warn about it.
"""
macro mutable(args...)
    error("`@mutable` is only valid as a statement of a `@CompositeAlgorithm` or `@Routine` block.")
end

"""Whether a DSL producer is the block's `@input`s."""
_dsl_is_input_owner(owner) = false
_dsl_is_input_owner(owner::AbstractIdentifiableAlgo) = getalgo(owner) isa RuntimeInputState

_dsl_is_mutable(stmt) = stmt isa Expr && stmt.head == :macrocall && stmt.args[1] == Symbol("@mutable")

"""The statement inside `@mutable stmt`."""
function _dsl_mutable_inner(stmt)
    args = [a for a in stmt.args[2:end] if !(a isa LineNumberNode)]
    length(args) == 1 || error("`@mutable` takes one statement: `@mutable y = f()` or `@mutable local x`. Got `$stmt`.")
    return only(args)
end

"""The names `@mutable stmt` marks (those `stmt` assigns or declares), or `nothing` when `stmt` is not `@mutable`."""
function _dsl_mutable_names(stmt)
    _dsl_is_mutable(stmt) || return nothing
    inner = _dsl_mutable_inner(stmt)
    if inner isa Expr && inner.head == :local
        targets = length(inner.args) == 1 && inner.args[1] isa Expr && inner.args[1].head == :tuple ? inner.args[1].args : inner.args
        return [first(_dsl_local_target(target, Set{Symbol}())) for target in targets]
    elseif inner isa Expr && inner.head == :(=)
        lhs = inner.args[1]
        lhs isa Expr && lhs.head == :(::) && (lhs = lhs.args[1])
        outputs = _dsl_try_parse_output_symbols(lhs)
        isnothing(outputs) || return collect(outputs)
    end
    error("`@mutable` marks an assignment or a declaration: `@mutable y = f()`, `@mutable local x`. Got `$stmt`.")
end

"""
Check the values an algorithm statement passes to the arguments the algorithm updates (`updated_names`): a value of
the block that is not state changes too, so building the block warns unless it was declared `@mutable`. An `@input`,
an outside value, or a value read through `@transform` cannot be updated: an error.
"""
function _composite_dsl_check_updates(entity, inputs::Tuple, producers::Dict{Symbol, Any}, state_owners::Dict{Symbol, Any}, mutable::Set{Symbol})
    @nospecialize entity inputs
    algo = entity isa AbstractIdentifiableAlgo ? getalgo(entity) : entity
    updated = updated_names(algo isa Type ? algo : typeof(algo))
    isempty(updated) && return nothing
    algo_name = nameof(algo isa Type ? algo : typeof(algo))
    for input in inputs
        input.destination in updated || continue
        what = "`$(algo_name)` updates its argument `$(input.destination)`"
        input.kind in (:simple, :context_simple) || error("$what, which reads `$(input.source)` through a transform: that cannot be written back. Pass `$(input.source)` itself.")
        input.kind == :context_simple && continue                     # a field of an algorithm's or a block's state
        source = input.source
        haskey(producers, source) || error("$what, which is `$source` here: an `@input` or an outside value, which cannot be changed.")
        producer = producers[source]
        _dsl_is_input_owner(producer) && error("$what, which is `$source` here: an `@input`, which cannot be changed.")
        haskey(state_owners, source) && state_owners[source] === producer && continue   # a state field of the block
        source in mutable && continue
        _dsl_read_by_name(producer) || continue          # not a value of the block (a captured return or a local)
        @warn "$what, so it changes `$source` here. If that is intended, declare it with `@mutable` (`@mutable $source = ...` or `@mutable local $source`)." _id = (algo_name, source) maxlog = 1
    end
    return nothing
end
