#=
Step 1 of `resolve` for a plan whose layout follows from its type: the registry and the keyed plan, built by code that
is specialised on the plan type without a generated function.

`make_registry_recipe(LA)` runs the type walk (`generate_registry_setup`) and turns the code it writes into a recipe: a
type made of the nodes below. It is `:foldable`, so Julia runs it while inferring a caller that knows `LA`, and the
recipe is a constant there. `build_from_recipe` then builds `(registry, keyed la)` from the recipe with inlined
methods, so the compiled code is the straight-line code the walk wrote.

What keeps the compile cost down:
- Coarse nodes: a keyed handle, a lookup table with its runtime keys, and a rebuilt plan node (its unchanged fields
  read from it once) are one node each; a constant tuple is one constant.
- One method per depth: the nodes that contain nodes (`RecipeCall`, `RecipeTuple`, `RecipeRebuild`) have a separate
  method for every depth up to `RECIPE_MAX_DEPTH`, so no pair of methods calls itself again during inference. When one
  does, Julia's recursion limiter compares the (large) recipe types at every level, which cost half the compile time.
  Deeper recipes use one shared method for the rest (`Val(:deep)`): the same result, compiled more slowly.
A form of code the recipe has no node for makes the plan use the run-time setup (`build_registry_from_values`).
=#

struct RecipeArg end                     # the plan `la`
struct RecipeLit{V} end                  # the constant V
struct RecipeFloats{V} end               # Float64[V...]
struct RecipePath{P} end                 # getfield(getfield(la, p1), p2)...: P = Tuple{Val{p1}, Val{p2}, ...}
struct RecipeCall{F, A} end              # F(args...): A = Tuple{argument nodes...}
struct RecipeTuple{A} end                # (args...)
struct RecipeHandle{KT, P} end           # KT(h.func, h.reconstructor) of the handle h at path P
struct RecipeLookup{K, I, R} end         # lookup table: names K = Tuple{Val{name}...} => indices I, then the keys R
struct RecipeKey{I, R} end               # in a `RecipeLookup`: d[dynamic_lookup_key(the value of node R)] = I
struct RecipeRebuild{T, P, A} end        # T(fields...) from the struct at path P: A = Tuple{RecipeCopy or a node...}
struct RecipeCopy end                    # in a `RecipeRebuild`: the field as the source struct has it

const RECIPE_MAX_DEPTH = 24     # depths with a method of their own
const RECIPE_MAX_ARITY = 8      # arguments of a call or tuple written out in one method (more: `build_all_from_recipe`)
const RECIPE_MAX_PATH = 16      # fields in a path, and in a rebuilt struct
const RECIPE_MAX_ARGS = 64      # arguments of a call or tuple
const RECIPE_MAX_KEYS = 32      # runtime keys of a lookup table

struct NotInRecipe <: Exception end   # thrown for code the recipe has no node for

###############################################################################
# Making the recipe (while inferring)
###############################################################################

"""
    make_registry_recipe(LA) -> recipe type

The recipe of `build_registry_and_key_plan` for a plan of type `LA`: the code the type walk writes
(`generate_registry_setup`) as a type of recipe nodes, or a call to `build_registry_from_values` when it has a form no node
stands for. `:foldable`, so a caller that knows `LA` gets it as a constant.
"""
Base.@assume_effects :foldable Base.@nospecializeinfer function make_registry_recipe(@nospecialize(LA))
    try
        return encode_recipe(generate_registry_setup(LA))
    catch e
        e isa NotInRecipe || rethrow()
        return RecipeCall{build_registry_from_values, Tuple{RecipeArg}}
    end
end

"""Whether `v` can be a type parameter of a recipe node as it is."""
is_recipe_constant(@nospecialize(v)) = isbits(v) || v isa Symbol || v isa Type

"""The node for the constant `v`; a tuple that cannot be one constant is a `RecipeTuple` of its elements."""
Base.@nospecializeinfer function encode_constant(@nospecialize(v))
    is_recipe_constant(v) && return RecipeLit{v}
    v isa Tuple || throw(NotInRecipe())
    args = Any[]
    for x in v
        push!(args, encode_constant(x))
    end
    return RecipeTuple{Tuple{args...}}
end

"""
    encode_path(x) -> Tuple{Val{p1}, Val{p2}, ...} or nothing

The fields `x` reads from `la` when `x` is `getfield(getfield(la, p1), p2)...`, else `nothing`.
"""
Base.@nospecializeinfer function encode_path(@nospecialize(x))
    fields = Any[]
    y = x
    while y isa Expr && y.head === :call && length(y.args) == 3 && y.args[1] === getfield
        pushfirst!(fields, Val{unquote(y.args[3])})
        y = y.args[2]
    end
    (y === :la && !isempty(fields) && length(fields) <= RECIPE_MAX_PATH) || return nothing
    return Tuple{fields...}
end
unquote(@nospecialize(x)) = x isa QuoteNode ? x.value : x

"""Whether `x` is `getfield(src, :field)` of the given `src`."""
reads_field(@nospecialize(x), @nospecialize(src), field::Symbol) =
    x isa Expr && x.head === :call && length(x.args) == 3 && x.args[1] === getfield && x.args[2] == src &&
        unquote(x.args[3]) === field

"""
    encode_recipe(x) -> recipe node

The node for `x`, a part of the code the type walk writes; throws `NotInRecipe` for a form no node stands for.
"""
Base.@nospecializeinfer function encode_recipe(@nospecialize(x))
    x === :la && return RecipeArg
    x isa QuoteNode && return encode_constant(x.value)
    x isa Expr || return encode_constant(x)
    P = encode_path(x)
    P === nothing || return RecipePath{P}
    if x.head === :call
        f = x.args[1] isa Symbol ? getfield(@__MODULE__, x.args[1]) : x.args[1]
        is_recipe_constant(f) || throw(NotInRecipe())
        n = length(x.args) - 1
        n <= RECIPE_MAX_ARGS || throw(NotInRecipe())
        f === lookup_table && return encode_lookup_table(x, Any[])
        if f isa Type && f <: IdentifiableAlgo && n == 2   # KT(h.func, h.reconstructor)
            h = x.args[2] isa Expr ? x.args[2].args[2] : nothing
            if h !== nothing && reads_field(x.args[2], h, :func) && reads_field(x.args[3], h, :reconstructor)
                Ph = encode_path(h)
                Ph === nothing || return RecipeHandle{f, Ph}
            end
        end
        rebuilt = encode_rebuild(f, x)
        rebuilt === nothing || return rebuilt
        args = Any[]
        for k in 2:length(x.args)
            push!(args, encode_recipe(x.args[k]))
        end
        return RecipeCall{f, Tuple{args...}}
    elseif x.head === :tuple
        length(x.args) <= RECIPE_MAX_ARGS || throw(NotInRecipe())
        if all(a -> a isa QuoteNode && is_recipe_constant(a.value), x.args)
            return RecipeLit{Tuple(Any[a.value for a in x.args])}
        end
        args = Any[]
        for a in x.args
            push!(args, encode_recipe(a))
        end
        return RecipeTuple{Tuple{args...}}
    elseif x.head === :ref && x.args[1] === Float64
        return RecipeFloats{Tuple(Float64[Float64(a) for a in x.args[2:end]])}
    elseif x.head === :let
        # let d = lookup_table(keys, idxs); setindex!(d, i, dynamic_lookup_key(algo))...; d end
        filled = x.args[1].args[2]
        sets = x.args[2].args
        keys = Any[]
        for k in 1:length(sets)-1
            R = encode_recipe(sets[k].args[4].args[2])
            R <: Union{RecipePath, RecipeHandle} || throw(NotInRecipe())
            push!(keys, RecipeKey{sets[k].args[3]::Int, R})
        end
        return encode_lookup_table(filled, keys)
    end
    throw(NotInRecipe())
end

"""The node for `lookup_table(keys, idxs)` (the call `x`), with the runtime keys `runtime` added after it."""
Base.@nospecializeinfer function encode_lookup_table(@nospecialize(x), runtime::Vector{Any})
    (x isa Expr && x.head === :call && x.args[1] === lookup_table) || throw(NotInRecipe())
    length(runtime) <= RECIPE_MAX_KEYS || throw(NotInRecipe())
    keys = x.args[2]::Tuple
    names = Any[Val{getfield(keys, j).name} for j in 1:length(keys)]
    return RecipeLookup{Tuple{names...}, x.args[3]::Tuple, Tuple{runtime...}}
end

"""
    encode_rebuild(T, x) -> RecipeRebuild or nothing

The node for the call `x` = `T(fields...)` when it rebuilds a struct: some fields are `getfield(src, k)` at their own
position `k`, all of one struct `src` at a path. `nothing` when `x` is not such a call.
"""
Base.@nospecializeinfer function encode_rebuild(@nospecialize(T), @nospecialize(x))
    n = length(x.args) - 1
    (T isa DataType && isstructtype(T) && n == fieldcount(T) && n <= RECIPE_MAX_PATH) || return nothing
    src = nothing
    fields = Any[nothing for _ in 1:n]
    for k in 1:n
        a = x.args[k + 1]
        a isa Expr && a.head === :call && length(a.args) == 3 && a.args[1] === getfield || continue
        unquote(a.args[3]) == k && (src === nothing || a.args[2] == src) || continue
        src = a.args[2]
        fields[k] = RecipeCopy
    end
    src === nothing && return nothing
    P = encode_path(src)
    P === nothing && return nothing
    for k in 1:n
        fields[k] === nothing && (fields[k] = encode_recipe(x.args[k + 1]))
    end
    return RecipeRebuild{T, P, Tuple{fields...}}
end

###############################################################################
# Building from the recipe (compiled code)
###############################################################################

"""The constant `(names...,)` of `Tuple{Val{name}...}`; `:foldable`, so it is a constant in compiled code."""
Base.@assume_effects :foldable Base.@nospecializeinfer names_of(@nospecialize(K)) = Tuple(Any[p.parameters[1] for p in K.parameters])

"""A new lookup table with `LookupKey(names[i]) => idxs[i]`. Compiled once."""
Base.@nospecializeinfer function new_lookup_table(@nospecialize(names::Tuple), @nospecialize(idxs::Tuple))
    d = Dict{LookupKey,Int}()
    sizehint!(d, length(names))
    for i in 1:length(names)
        d[LookupKey(getfield(names, i)::Symbol)] = getfield(idxs, i)::Int
    end
    return d
end

"""
    build_from_recipe(depth, R, la) -> value

The value the recipe node `R` stands for, read from or built from the plan `la`. `depth` (`Val(d)`) selects the method
for the node's depth; leaves have one method for every depth.
"""
function build_from_recipe end

@inline build_from_recipe(::Val{D}, ::Type{RecipeArg}, la::L) where {D, L} = la
@inline build_from_recipe(::Val{D}, ::Type{RecipeLit{V}}, la::L) where {D, V, L} = V
@inline build_from_recipe(::Val{D}, ::Type{RecipeFloats{V}}, la::L) where {D, V, L} = Float64[V...]

# Paths and handles, one method per path length.
for n in 1:RECIPE_MAX_PATH
    ps = [Symbol(:p, k) for k in 1:n]
    read = foldl((acc, p) -> :(getfield($acc, $p)), ps; init = :la)
    path = :(Tuple{$((:(Val{$p}) for p in ps)...)})
    @eval @inline build_from_recipe(::Val{D}, ::Type{RecipePath{$path}}, la::L) where {D, $(ps...), L} = $read
    @eval @inline build_from_recipe(::Val{D}, ::Type{RecipeHandle{KT, $path}}, la::L) where {D, KT, $(ps...), L} =
        (h = $read; KT(getfield(h, :func), getfield(h, :reconstructor)))
end

# Lookup tables, one method per number of runtime keys: the fixed keys from a table built once, the runtime keys
# written out.
for n in 0:RECIPE_MAX_KEYS
    is = [Symbol(:i, j) for j in 1:n]
    rs = [Symbol(:R, j) for j in 1:n]
    keys = :(Tuple{$((:(RecipeKey{$(is[j]), $(rs[j])}) for j in 1:n)...)})
    sets = [:(d[dynamic_lookup_key(build_from_recipe(Val(0), $(rs[j]), la))] = $(is[j])) for j in 1:n]
    @eval @inline build_from_recipe(::Val{D}, ::Type{RecipeLookup{K, I, $keys}}, la::L) where {D, K, I, $(is...), $(rs...), L} =
        (d = new_lookup_table(names_of(K), I); $(sets...); d)
end

# Nodes that contain nodes: one method per depth, then one for every deeper level.
for d in Any[1:RECIPE_MAX_DEPTH..., :deep]
    depth = QuoteNode(d)
    next = d === :deep || d == RECIPE_MAX_DEPTH ? :(Val(:deep)) : :(Val($(d + 1)))
    for n in 0:RECIPE_MAX_ARITY
        as = [Symbol(:a, k) for k in 1:n]
        args = [:(build_from_recipe($next, $a, la)) for a in as]
        @eval @inline build_from_recipe(::Val{$depth}, ::Type{RecipeCall{F, Tuple{$(as...)}}}, la::L) where {F, $(as...), L} =
            F($(args...))
        @eval @inline build_from_recipe(::Val{$depth}, ::Type{RecipeTuple{Tuple{$(as...)}}}, la::L) where {$(as...), L} =
            ($(args...),)
    end
    @eval @inline build_from_recipe(::Val{$depth}, ::Type{RecipeCall{F, A}}, la::L) where {F, A, L} =
        F(build_all_from_recipe($next, A, la)...)
    @eval @inline build_from_recipe(::Val{$depth}, ::Type{RecipeTuple{A}}, la::L) where {A, L} =
        build_all_from_recipe($next, A, la)
    for n in 1:RECIPE_MAX_PATH
        fs = [Symbol(:F, k) for k in 1:n]
        fields = [:($(fs[k]) === RecipeCopy ? getfield(src, $k) : build_from_recipe($next, $(fs[k]), la)) for k in 1:n]
        @eval @inline build_from_recipe(::Val{$depth}, ::Type{RecipeRebuild{T, P, Tuple{$(fs...)}}}, la::L) where {T, P, $(fs...), L} =
            (src = build_from_recipe(Val(0), RecipePath{P}, la); T($(fields...)))
    end
end

"""The tuple of the values of the nodes in `A` (`Tuple{nodes...}`), for calls and tuples with many arguments."""
function build_all_from_recipe end
for n in 0:RECIPE_MAX_ARGS
    as = [Symbol(:a, k) for k in 1:n]
    @eval @inline build_all_from_recipe(d::Val{D}, ::Type{Tuple{$(as...)}}, la::L) where {D, $(as...), L} =
        ($((:(build_from_recipe(d, $a, la)) for a in as)...),)
end

"""
    build_registry_and_key_plan(la) -> (registry, keyed_la)

The registry of the whole tree of `la`, and `la` with every child replaced by its raw algorithm and its key recorded
in its plan's `namespaces` (step 1 of `resolve`). Built from the recipe of `la`'s type (`make_registry_recipe`): the
compiled code only reads the algorithms out of `la` and puts them in place, and creates each entry type's multipliers
and lookup table anew. A plan whose layout needs its values (a state merge, an object that is not an `IdentifiableAlgo`
handle, a plan type not read from its fields) is set up at run time instead (`build_registry_from_values`).
"""
build_registry_and_key_plan(la::LA) where {LA<:LoopAlgorithm} = build_from_recipe(Val(1), make_registry_recipe(LA), la)
