## Currently unused. Provides a system to precompute when parts of a CompositeAlgorithm should run,
## instead of checking every time. However, accessing memory is quite slow.

mutable struct TriggerList{Always}
    const triggers::Vector{Int}
    idx::Int
end

TriggerList() = TriggerList{false}([], 1)

AlwaysTrigger() = TriggerList{true}([], 1)
TriggerList(v::Vector{Int}) = TriggerList{false}(v, 1)


InitTriggerList(interval) = interval == 1 ? AlwaysTrigger() : TriggerList()

Base.length(tl::TriggerList) = length(tl.triggers)
Base.size(tl::TriggerList) = size(tl.triggers)
isfinished(tl::TriggerList) = tl.idx > length(tl.triggers)


peeknext(tl::TriggerList) = tl.triggers[tl.idx]

next!(tl::TriggerList) = tl.idx += 1
next!(tl::TriggerList{true}) = nothing

mutable struct CompositeTriggers{N, TL}
    const lists::TL
    listidx::Int
end

Base.getindex(ct::CompositeTriggers, i) = ct.lists[i]

CompositeTriggers(lists) = CompositeTriggers{length(lists), typeof(lists)}(lists, 1)
inc!(ct::CompositeTriggers) = ct.lists[ct.listidx] |> next!

@inline peeknext(ct::CompositeTriggers) = ct.lists[ct.listidx] |> peeknext
function shouldtrigger(ct::CompositeTriggers, loopidx)
    if thislist(ct) |> isfinished
        return false
    end
    return peeknext(ct) == loopidx
end

skiplist!(ct::CompositeTriggers) = ct.listidx = mod1(ct.listidx + 1, length(ct.lists))
thislist(ct::CompositeTriggers) = ct.lists[ct.listidx]
maxtriggers(ct::CompositeTriggers) = length(thislist(ct))
triggeridx(ct::CompositeTriggers) = thislist(ct).idx