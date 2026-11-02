#=
The `LoopContext` constructor: makes the bundle a run starts from out of the process's context as the user sees it (its
registry has the plan's `UniqueKeyMap`) and the run's inputs. Generated: the generator works out the bundle's type from
the argument types (the context without the map, the inputs checked against the plan's `@input`s and merged with their
defaults, the plan's declared locals) and the body builds it directly, so its type is known wherever it is called, also
for a plan with inputs. After LoopAlgorithms/: the generator reads the `@input` declarations and the declared locals
from the plan's type (`_tree_locals!`, Locals.jl), and a generator only calls functions defined before it.
=#

# Generator helpers: types and expressions in, types and expressions out. Untyped, so compiled once.

"""The `LoopAlgorithm` type under the `FinalizedAlgorithm`s of plan type `A`, and the expression reaching it from `expr`."""
function _loop_algorithm_at(@nospecialize(A::Type), @nospecialize(expr))
    while A <: FinalizedAlgorithm
        A, expr = fieldtype(A, :inner), :(getfield($expr, :inner))
    end
    A <: LoopAlgorithm || error("A `LoopContext` is made for a `LoopAlgorithm` or `FinalizedAlgorithm`, got `$A`.")
    return A, expr
end

"""
The `RuntimeInput` types plan type `A` declares, each with the expression of its value (from `expr`), found where
`runtimeinputs` finds them: in the plan's `RuntimeInputs` options, else in its `RuntimeInputState` states.
"""
function _runtime_input_specs_at(@nospecialize(A::Type), @nospecialize(expr))
    A, expr = _loop_algorithm_at(A, expr)
    specs = Pair{Any, Any}[]
    O = fieldtype(A, :options)
    for i in 1:fieldcount(O)
        fieldtype(O, i) <: RuntimeInputs || continue
        S = fieldtype(fieldtype(O, i), :specs)
        for j in 1:fieldcount(S)
            push!(specs, fieldtype(S, j) => :(getfield(getfield(getfield(getfield($expr, :options), $i), :specs), $j)))
        end
    end
    isempty(specs) || return specs
    St = fieldtype(fieldtype(A, :plan), :states)
    for i in 1:fieldcount(St)
        X, xexpr = fieldtype(St, i), :(getfield(getfield(getfield($expr, :plan), :states), $i))
        X <: IdentifiableAlgo && ((X, xexpr) = (fieldtype(X, :func), :(getfield($xexpr, :func))))
        X <: RuntimeInputState || continue
        S = fieldtype(X, :specs)
        for j in 1:fieldcount(S)
            push!(specs, fieldtype(S, j) => :(getfield(getfield($xexpr, :specs), $j)))
        end
    end
    return specs
end

"""
The run's inputs `inputs` (type `I`) checked against `specs` (`_runtime_input_specs_at`): an expression that is the
checked inputs, and their type. As `merge(defaults, inputs)`: the optional inputs' defaults first, in declaration order,
an input given replaces its default, the other inputs after. A check that fails from the types alone gives an
expression that throws (type `Union{}`): an unknown input, a required one missing, a value of the wrong type.
"""
function _checked_inputs_at(specs::Vector{Pair{Any, Any}}, @nospecialize(I::Type))
    given = fieldnames(I)
    if isempty(specs)
        isempty(given) || return :(error("Runtime inputs were passed, but this LoopAlgorithm declares no @input values.")), Union{}
        return :inputs, I
    end
    declared = Tuple(first(spec).parameters[1] for spec in specs)
    for name in given
        name in declared || return :(error($("Unknown runtime input `$name`. Declared inputs are $(declared)."))), Union{}
    end
    checks, names, values, types = Any[], Symbol[], Any[], Any[]
    for (spec, specexpr) in specs
        name, T, required = spec.parameters[1], spec.parameters[2], spec.parameters[3]
        if name in given
            V = fieldtype(I, name)
            V <: T || push!(checks, :(getfield(inputs, $(QuoteNode(name))) isa $T ||
                error("Runtime input `", $(QuoteNode(name)), "` has type ", typeof(getfield(inputs, $(QuoteNode(name)))), ", expected `", $T, "`.")))
        elseif required
            return :(error($("Missing required runtime input `$name`."))), Union{}
        end
        required && continue
        push!(names, name)
        name in given ? (push!(values, :(getfield(inputs, $(QuoteNode(name))))); push!(types, fieldtype(I, name))) :
                        (push!(values, :(getfield($specexpr, :default))); push!(types, fieldtype(spec, :default)))
    end
    for name in given
        name in names && continue
        push!(names, name); push!(values, :(getfield(inputs, $(QuoteNode(name))))); push!(types, fieldtype(I, name))
    end
    VI = NamedTuple{Tuple(names), Tuple{types...}}
    return :($(checks...); $VI(($(values...),))), VI
end

"""Context type `C` without its registry's map, and the expression making it from `expr`; `C` as it is when it has no map."""
function _without_keymap_at(@nospecialize(C::Type), @nospecialize(expr))
    R = fieldtype(C, :reg)
    (R <: Base.RefValue && fieldtype(R, :x) <: NameSpaceRegistry) || return expr, C
    E, M = fieldtype(R, :x).parameters
    M === Nothing && return expr, C
    Reg = NameSpaceRegistry{E, Nothing}
    NC = ProcessContext{fieldtype(C, :subcontexts), Base.RefValue{Reg}}
    return :($NC(getfield($expr, :subcontexts), Base.RefValue{$Reg}($Reg(getfield(getfield($expr, :reg)[], :entries), nothing)))), NC
end

"""
A runtime context with the subcontexts `_inputs` (type `VI`, from `inputs_expr`) and `_declared_locals` (type `L`), each
only when not empty, as `_initial_runtime_context` makes it: the expression and its type.
"""
function _runtime_context_at(@nospecialize(VI::Type), @nospecialize(inputs_expr), @nospecialize(L::Type), @nospecialize(locals_expr))
    names, types, values = Symbol[], Any[], Any[]
    for (name, T, expr) in ((:_inputs, VI, inputs_expr), (:_declared_locals, L, locals_expr))
        fieldcount(T) == 0 && continue
        push!(names, name); push!(types, SubContext{name, T}); push!(values, :($(SubContext{name, T})($expr)))
    end
    D = NamedTuple{Tuple(names), Tuple{types...}}
    RC = ProcessContext{D, Nothing}
    return :($RC($D(($(values...),)), nothing)), RC
end

"""
Paused context type `C` (already without the map, from `expr`) made ready to resume, as `_paused_state_context` and
`_initial_runtime_context` make it: the persistent context with its `_inputs` and `_declared_locals` emptied, and the
runtime context with the inputs and declared locals it kept. Returns both expressions and both types.
"""
function _resumed_contexts_at(@nospecialize(C::Type), @nospecialize(expr))
    D = fieldtype(C, :subcontexts)
    kept(name) = name in fieldnames(D) ? (fieldtype(fieldtype(D, name), :data), :(getfield(getfield(getfield($expr, :subcontexts), $(QuoteNode(name))), :data))) :
                                         (NamedTuple{(), Tuple{}}, :(NamedTuple()))
    (VI, inputs_expr), (L, locals_expr) = kept(:_inputs), kept(:_declared_locals)
    types, values = Any[], Any[]
    for name in fieldnames(D)
        if name in (:_inputs, :_declared_locals)
            S = SubContext{name, NamedTuple{(), Tuple{}}}
            push!(types, S); push!(values, :($S(NamedTuple())))
        else
            push!(types, fieldtype(D, name)); push!(values, :(getfield(getfield($expr, :subcontexts), $(QuoteNode(name)))))
        end
    end
    ND = NamedTuple{fieldnames(D), Tuple{types...}}
    PC = ProcessContext{ND, fieldtype(C, :reg)}
    rc_expr, RC = _runtime_context_at(VI, inputs_expr, L, locals_expr)
    return :($PC($ND(($(values...),)), getfield($expr, :reg))), PC, rc_expr, RC
end

"""
    LoopContext(plan, context, inputs, resume)

The `LoopContext` a run starts from, made where a run is handed to the loop (`run(ip)`, a `Process` run, the manager's
inline run, `run(plan)`). `context` is the process's context as the user sees it: its registry has the plan's
`UniqueKeyMap`, which is dropped here, so the loop is compiled once for every set of `Unique` handles. A new run
(`Resuming{false}`) gets the inputs, checked against the plan's `@input`s and merged with their defaults, and the plan's
declared locals as its runtime context. A paused run that resumes (`Resuming{true}`) gets the inputs and declared locals
kept in the paused context, which are emptied in the persistent context; `inputs` is not used then.

Generated: the bundle's type is worked out from the argument types, so it is known where the constructor is called, and
an input check that fails from the types alone is an error thrown before the run.
"""
@generated function LoopContext(algo::A, context::C, inputs::I, ::Resuming{isresuming}) where {A, C<:ProcessContext, I<:NamedTuple, isresuming}
    persistent_expr, PC0 = _without_keymap_at(C, :context)
    if isresuming
        pc_expr, PC, rc_expr, RC = _resumed_contexts_at(PC0, :persistent_context)
        return quote
            $(Expr(:meta, :inline))
            persistent_context = $persistent_expr
            return $(LoopContext{PC, RC, Nothing})($pc_expr, $rc_expr)
        end
    end
    checked_expr, VI = _checked_inputs_at(_runtime_input_specs_at(A, :algo), I)
    VI === Union{} && return checked_expr
    LA, la_expr = _loop_algorithm_at(A, :algo)
    local_names, local_values, local_types = _tree_locals!(Symbol[], Any[], Any[], fieldtype(LA, :plan), :(getfield($la_expr, :plan)), ())
    L = NamedTuple{Tuple(local_names), Tuple{local_types...}}
    rc_expr, RC = _runtime_context_at(VI, :checked_inputs, L, :($L(($(local_values...),))))
    return quote
        $(Expr(:meta, :inline))
        checked_inputs = $checked_expr
        return $(LoopContext{PC0, RC, Nothing})($persistent_expr, $rc_expr)
    end
end
