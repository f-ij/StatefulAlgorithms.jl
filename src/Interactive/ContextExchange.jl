export ContextExchange, interact!, isinteractive

struct ResolvedExchangeVar{Name, Subcontext, Varname, T}
    initial::T
end

ResolvedExchangeVar(name::Symbol, subcontext::Symbol, varname::Symbol, initial::T) where {T} =
    ResolvedExchangeVar{name, subcontext, varname, T}(initial)

@inline _exchange_name(::ResolvedExchangeVar{Name}) where {Name} = Name
@inline _exchange_name(::Type{<:ResolvedExchangeVar{Name}}) where {Name} = Name
@inline _exchange_subcontext(::Type{<:ResolvedExchangeVar{Name, Subcontext}}) where {Name, Subcontext} = Subcontext
@inline _exchange_varname(::Type{<:ResolvedExchangeVar{Name, Subcontext, Varname}}) where {Name, Subcontext, Varname} = Varname
@inline _exchange_vartype(::Type{<:ResolvedExchangeVar{Name, Subcontext, Varname, T}}) where {Name, Subcontext, Varname, T} = T

"""
Mutable buffers shared by `ContextExchange` and `ContextExchangeVar`.

The `Specs` type parameter contains the fully resolved `(exchange name,
subcontext, variable)` triplets produced during init. Hot stepping specializes on
that type and does not use routing/wiring lookup.
"""
mutable struct ContextExchangeStore{Specs, Published, Pending, HasPending, Subscribed, LastTime}
    published::Published
    pending::Pending
    haspending::HasPending
    subscribed::Subscribed
    lasttime::LastTime
    period::Float64
end

@generated function ContextExchangeStore(specs::Specs, period::Float64) where {Specs<:Tuple}
    spec_types = Specs.parameters
    names = tuple((_exchange_name(spec) for spec in spec_types)...)
    published_values = map(enumerate(spec_types)) do (i, spec)
        T = _exchange_vartype(spec)
        :(Ref{$T}(getfield(getfield(specs, $i), :initial)))
    end
    pending_values = map(enumerate(spec_types)) do (i, spec)
        T = _exchange_vartype(spec)
        :(Ref{$T}(getfield(getfield(specs, $i), :initial)))
    end
    haspending_values = (:(Ref(false)) for _ in names)
    subscribed_values = (:(Ref(false)) for _ in names)

    return quote
        published = NamedTuple{$names}(($(published_values...),))
        pending = NamedTuple{$names}(($(pending_values...),))
        haspending = NamedTuple{$names}(($(haspending_values...),))
        subscribed = NamedTuple{$names}(($(subscribed_values...),))
        lasttime = Ref(-Inf)
        return ContextExchangeStore{$Specs, typeof(published), typeof(pending), typeof(haspending), typeof(subscribed), typeof(lasttime)}(
            published,
            pending,
            haspending,
            subscribed,
            lasttime,
            period,
        )
    end
end

"""
Scheduled two-way exchange for concrete `Var` selectors.

Selectors are supplied as init values, for example:

```julia
ContextExchange()
Init(:_exchange; vars = (Var(:target, :value), :display_seen => Var(MyAlgo, :seen)))
```

Init resolves those selectors against the process registry/context and stores
the resolved paths in `ContextExchangeStore`. The exchange has a custom `_step!`
so it can read and write those paths directly.
"""
struct ContextExchange{Key} <: AbstractIdentifiableAlgo{
    ContextExchange,
    ValMatcher(:ContextExchange),
    VarAliases(),
    Symbol(),
    Key,
}
    period::Float64
end

ContextExchange(; period::Real = 0.0) = ContextExchange{:_exchange}(Float64(period))

@inline exchange_period(exchange::ContextExchange) = getfield(exchange, :period)
@inline Base.getkey(exchange::ContextExchange) = getkey(typeof(exchange))
@inline Base.getkey(::Type{<:ContextExchange{Key}}) where {Key} = Key
@inline getalgo(exchange::ContextExchange) = exchange
@inline getalgos(exchange::ContextExchange) = (exchange,)
@inline setcontextkey(exchange::ContextExchange, key::Symbol) =
    ContextExchange{key}(exchange_period(exchange))
@inline setid(exchange::ContextExchange, newid) = exchange
@inline setvaraliases(exchange::ContextExchange, newaliases) = exchange
@inline match_by(::Union{ContextExchange, Type{<:ContextExchange}}) = ValMatcher(:ContextExchange)
@inline registry_entrytype(::Type{<:ContextExchange}) = ContextExchange
@inline isstaticallyfindable(::ContextExchange) = true
@inline Autokey(exchange::ContextExchange, i::Int; customname = Symbol(), aliases...) =
    haskey(exchange) ? exchange : setcontextkey(exchange, static_symbol(:ContextExchange_, i))

function _context_exchange_state(exchange::ContextExchange, context::ProcessContext)
    specs = _resolve_exchange_specs(context, _exchange_init_selectors(context, getkey(exchange)))
    store = ContextExchangeStore(specs, exchange_period(exchange))
    return (; store)
end

function StatefulAlgorithms.init(exchange::ContextExchange, ::NamedTuple = (;))
    error("ContextExchange init needs a ProcessContext so its Var selectors can be resolved.")
end

function StatefulAlgorithms.init(exchange::ContextExchange, context::C) where {C<:ProcessContext}
    key = getkey(exchange)
    return replace(context, NamedTuple{(key,)}((_context_exchange_state(exchange, context),)))
end

@inline StatefulAlgorithms.cleanup(::ContextExchange, context::AbstractContext) = context

"""
    _exchange_init_selectors(context, key)

Read the init-only `vars` tuple for a `ContextExchange` namespace before that
namespace is replaced by its resolved store.
"""
@inline function _exchange_init_selectors(context::ProcessContext, key::Symbol)
    data = getdata(getproperty(context, key))
    haskey(data, :vars) || error("ContextExchange requires init selectors: Init($(key); vars = (...,)).")
    selectors = getfield(data, :vars)
    selectors isa Tuple || error("ContextExchange init field `vars` must be a tuple of Var selectors or name => Var pairs.")
    return selectors
end

function _resolve_exchange_specs(context::ProcessContext, selectors::Tuple)
    return ntuple(i -> _resolve_exchange_spec(context, selectors[i]), length(selectors))
end

@inline _exchange_selector_pair(selector::Var{Entity, Varname}) where {Entity, Varname} = Varname => selector
@inline _exchange_selector_pair(pair::Pair{Symbol, <:Var}) = pair

function _resolve_exchange_spec(context::ProcessContext, selector)
    name, var = _exchange_selector_pair(selector)
    subcontext, varname, initial = _resolve_exchange_var(context, var)
    return ResolvedExchangeVar(name, subcontext, varname, initial)
end

function _resolve_exchange_var(context::ProcessContext, ::Var{Entity, Varname}) where {Entity, Varname}
    Entity == :globals && error("ContextExchange selectors must target stored subcontext variables, not globals.")
    subcontext = _resolve_exchange_entity(context, Entity)
    initial = _validate_exchange_target(context, subcontext, Varname)
    return subcontext, Varname, initial
end

function _resolve_exchange_entity(context::ProcessContext, entity::Symbol)
    entity in get_subcontexts_fieldnames(typeof(context)) || error("ContextExchange target subcontext $(entity) not found.")
    return entity
end

function _resolve_exchange_entity(context::ProcessContext, entity::Type)
    matches = findall(entity, getregistry(context))
    if isempty(matches)
        error("No algorithm matching $(entity) was found in the registry.")
    elseif length(matches) > 1
        error("Context has multiple algorithms matching $(entity): $(getkey.(matches)). Use a keyed Var selector.")
    end
    return getkey(only(matches))
end

function _resolve_exchange_entity(context::ProcessContext, entity)
    return getkey(getregistry(context)[entity])
end

function _validate_exchange_target(context::ProcessContext, subcontext::Symbol, varname::Symbol)
    subctx = getproperty(context, subcontext)
    haskey(getdata(subctx), varname) || error("ContextExchange target variable $(subcontext).$(varname) not found.")
    return getproperty(subctx, varname)
end

function _default_exchange_key(context::ProcessContext)
    matches = _context_exchanges(context)
    isempty(matches) && error("Context has no ContextExchange in its registry.")
    length(matches) > 1 && error("Context has multiple ContextExchange entries: $(getkey.(matches)). Pass `exchange = :key`.")
    return getkey(only(matches))
end

@inline function _context_exchange_store(context::ProcessContext, exchange::Union{Nothing, Symbol} = nothing)
    key = isnothing(exchange) ? _default_exchange_key(context) : exchange
    return getfield(getdata(getfield(get_subcontexts(context), key)), :store)
end

function _context_exchanges(context::ProcessContext)
    matches = findall(ContextExchange, getregistry(context))
    return matches
end

@inline isinteractive(context::ProcessContext) = !isempty(_context_exchanges(context))
@inline isinteractive(process::AbstractProcess) = isinteractive(context(process))

@inline function _context_exchange_due!(store::ContextExchangeStore)
    period = getfield(store, :period)
    period <= 0 && return true

    now = time()
    lasttime = getfield(store, :lasttime)
    if now - lasttime[] >= period
        lasttime[] = now
        return true
    end
    return false
end

@inline function StatefulAlgorithms._step!(
    exchange::E,
    context::C,
    runtimecontext::RC,
    ::W,
    ::Namespace{Name},
    process::P,
    lifetime::LT,
) where {E<:ContextExchange, C<:ProcessContext, RC<:ProcessContext, W<:PlanWiringView, Name, P<:AbstractProcess, LT<:Lifetime}
    store = _context_exchange_store(context, Name)
    _context_exchange_due!(store) || return context, runtimecontext
    return (@inline _step_context_exchange_store(context, store)), runtimecontext
end

@inline function StatefulAlgorithms.step!(exchange::ContextExchange, context::C) where {C<:ProcessContext}
    store = _context_exchange_store(context, getkey(exchange))
    _context_exchange_due!(store) || return context
    return @inline _step_context_exchange_store(context, store)
end

@inline @generated function _step_context_exchange_store(context::C, store::ContextExchangeStore{Specs}) where {C<:ProcessContext, Specs}
    specs = Specs.parameters
    exprs = Expr[
        :(published = getfield(store, :published)),
        :(pending = getfield(store, :pending)),
        :(haspending = getfield(store, :haspending)),
        :(subscribed = getfield(store, :subscribed)),
    ]

    for spec in specs
        name = _exchange_name(spec)
        subcontext = _exchange_subcontext(spec)
        varname = _exchange_varname(spec)
        current = Symbol(:current_, name)
        pending_value = Symbol(:pending_, name)
        has_pending = Symbol(:has_pending_, name)
        is_subscribed = Symbol(:is_subscribed_, name)

        push!(exprs, :($has_pending = getproperty(haspending, $(QuoteNode(name)))[]))
        push!(
            exprs,
            quote
                if $has_pending
                    $pending_value = getproperty(pending, $(QuoteNode(name)))[]
                    getproperty(published, $(QuoteNode(name)))[] = $pending_value
                    getproperty(haspending, $(QuoteNode(name)))[] = false
                    context = @inline merge_into_subcontexts(
                        context,
                        NamedTuple{$((subcontext,))}((NamedTuple{$((varname,))}(($pending_value,)),)),
                    )
                else
                    $is_subscribed = getproperty(subscribed, $(QuoteNode(name)))[]
                    if $is_subscribed
                        $current = getproperty(getproperty(context, $(QuoteNode(subcontext))), $(QuoteNode(varname)))
                        getproperty(published, $(QuoteNode(name)))[] = $current
                    end
                end
            end,
        )
    end

    push!(exprs, :(return context))
    return Expr(:block, exprs...)
end

@inline @generated function _exchange_slot(store::ContextExchangeStore{Specs}, ::Val{name}) where {Specs, name}
    names = fieldnames(fieldtype(store, :published))
    name in names || error("ContextExchange does not expose variable $(name). Available variables are $(names).")
    return quote
        published = getfield(store, :published)
        pending = getfield(store, :pending)
        haspending = getfield(store, :haspending)
        subscribed = getfield(store, :subscribed)
        return getfield(published, $(QuoteNode(name))), getfield(pending, $(QuoteNode(name))), getfield(haspending, $(QuoteNode(name))), getfield(subscribed, $(QuoteNode(name)))
    end
end

"""Return the concrete target type accepted by a typed pending slot."""
@inline _pending_value_type(::Base.RefValue{T}) where {T} = T

"""
    interact!(context, :name => value; exchange = :_exchange)

Queue an external write to one resolved exchange variable. The next due exchange
step converts it to the current target variable type and writes it directly into
the resolved subcontext.
"""
function interact!(context::ProcessContext, pair::Pair{Symbol, <:Any}; exchange::Union{Nothing, Symbol} = nothing)
    _, pending, haspending, _ = _exchange_slot(_context_exchange_store(context, exchange), Val(first(pair)))
    pending[] = convert(_pending_value_type(pending), last(pair))
    haspending[] = true
    return context
end

interact!(process::AbstractProcess, pair::Pair{Symbol, <:Any}; exchange::Union{Nothing, Symbol} = nothing) =
    interact!(context(process), pair; exchange)

"""
Ref-like view of one exchange variable.

`ref[]` reads the last value published by the exchange. `ref[] = value` queues a
write for the next due exchange step.
"""
struct ContextExchangeVar{ExchangeKey, Varname, Published, Pending, HasPending}
    published::Published
    pending::Pending
    haspending::HasPending
end

@inline _interactive_varname(::ContextExchangeVar{ExchangeKey, Varname}) where {ExchangeKey, Varname} = Varname

function ContextExchangeVar(context::ProcessContext, varname::Symbol; exchange::Union{Nothing, Symbol} = nothing)
    published, pending, haspending, subscribed = _exchange_slot(_context_exchange_store(context, exchange), Val(varname))
    subscribed[] = true
    return ContextExchangeVar{exchange, varname, typeof(published), typeof(pending), typeof(haspending)}(published, pending, haspending)
end

function Base.view(context::ProcessContext, varname::Symbol; exchange::Union{Nothing, Symbol} = nothing)
    return ContextExchangeVar(context, varname; exchange)
end

function Base.view(context::ProcessContext, ::Var{Exchange, Varname}) where {Exchange, Varname}
    return ContextExchangeVar(context, Varname; exchange = Exchange)
end

@inline Base.getindex(ref::ContextExchangeVar) = getfield(ref, :published)[]

@inline function Base.setindex!(ref::ContextExchangeVar, value)
    pending = getfield(ref, :pending)
    pending[] = convert(_pending_value_type(pending), value)
    getfield(ref, :haspending)[] = true
    return value
end
