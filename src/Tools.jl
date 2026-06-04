export processsizehint!, recommendsize, newallocator, progress, est_remaining,
    num_calls, closeprocess

"""Return the lifetime visible to init-time sizing helpers."""
@inline sizing_lifetime(contextview::SubContextView) = view_lifetime(contextview)
@inline sizing_lifetime(contextview::ContextAnalyserView) = getglobals(contextview).lifetime

"""Return the current algorithm instance for init-time sizing helpers."""
@inline sizing_instance(contextview::Union{SubContextView, ContextAnalyserView}) = this_instance(contextview)

"""Return the scheduled call multiplier for init-time sizing helpers."""
@inline sizing_multiplier(contextview::SubContextView) = view_multiplier(contextview)
@inline sizing_multiplier(contextview::ContextAnalyserView) = getmultiplier(contextview, sizing_instance(contextview))

"""
Use within init function
For a process with a limited lifetime,
give the array a size hint based on the lifetime and the number of updates per step.
"""
@inline function processsizehint!(array, contextview::AbstractContext, updates_per_step = 1; print_hint = false)
    if !(contextview isa AbstractContext)
        @show contextview
        @warn("Cannot give a sizehint, init is not called from a process")
        return nothing
    end

    lifetime = @inline sizing_lifetime(contextview)
    if lifetime isa IndefiniteLifetime
        return sizehint!(array, 2^16)
    end

    multiplier = @inline sizing_multiplier(contextview)
    startsize = length(array)

    recommended_extra = ceil(Int, repeats(lifetime)*multiplier*updates_per_step)
    # @show recommended_extra
    # recommended_extra = recommendsize(args, updates_per_step)
    sizehint = startsize + recommended_extra
    # println("Recommended sizehint: $sizehint")
    # @show sizehint
    @DebugMode "Sizehint is $sizehint"
    if print_hint
        println("Recommended sizehint for $(@inline sizing_instance(contextview)) is: $sizehint")
    end
    sizehint!(array, sizehint)
end
# """
# Given an algorithm, return the number of times it will be called per loop of the process
# """
# function call_ratio(ph::PrepereHelper, algo)
#     if algo isa Type
#         algo = algo()
#     end
#     if !haskey(ph.counts, algo)
#         return 0
#     end
#     ph.repeats[algo]
# end

function getmultiplier(sct::SubContextView{CType, SubKey}, subpackage::SubPackage) where {CType, SubKey}
    registry = getregistry(sct)
    registered = registry[SubKey]
    package = getalgo(registered)
    package_multiplier = static_get_multiplier(registry, registered)
    sub_multiplier = getmultiplier(package, subpackage)
    return package_multiplier * sub_multiplier
end


"""
Get the number of times an algorithm will be called in a process
"""
function getmultiplier(contextview::AbstractContext, instance::ProcessAlgorithm)
    multiplier = getmultiplier(getregistry(contextview), instance)
    return multiplier
end

function num_calls(contextview, lifetime, instance)
    multiplier = getmultiplier(contextview, instance)
    if lifetime isa IndefiniteLifetime
        return typemax(Int)
    end
    floor(Int, repeats(lifetime)*multiplier)
end

function num_calls(contextview, lifetime, instance::SubPackage)
    multiplier = getmultiplier(contextview, instance)
    if lifetime isa IndefiniteLifetime
        return typemax(Int)
    end
    # @show multiplier
    floor(Int, repeats(lifetime)*multiplier)
end

"""
Get the number of times an algorithm will be called in a process
This is to be used in the init function
"""
function num_calls(contextview)
    lifetime = @inline sizing_lifetime(contextview)
    instance = @inline sizing_instance(contextview)
    num_calls(contextview, lifetime, instance)
end

"""
Gives the maximum loop index for a process
"""
function maximum_loopidx(p::Process)
    return repeats(p)
end

"""
Get the current loop index for a process
"""
loopidx(args::NamedTuple) = loopidx(args.process)

"""
TODO: Replace this
"""
algo_call_number(args) = loopidx(args.globalargs.process) ÷ args.globalargs.interval
export algo_call_number
# """
# Get the allocator directly from the args
# """
# getallocator(args) = getallocator(args.process)
# function newallocator(args)
#     if haskey(args, :algotracker)
#         if algoidx(args.algotracker) == 1
#             return args.process.allocator = Arena()
#         else
#             return getallocator(args)
#         end
#     end
# end

function closeprocess(c::AbstractProcess)
    globals = getglobals(c).process
    @assert haskey(globals, :process) "Process context does not have a :process key, cannot close process"
    proc = globals.process
    close(proc)
end


####
export TimeTracker, wait, add_timetracker
"""
A time tracker for waiting in loops
"""
mutable struct TimeTracker
    lasttime::UInt64
end
TimeTracker() = TimeTracker(0)
function Base.wait(timetracker::TimeTracker, seconds)
    while time_ns() - timetracker.lasttime < seconds*1e9
    end
    timetracker.lasttime = time_ns()
end

Base.wait(args::NamedTuple, seconds) = Base.wait(args.timetracker, seconds)
add_timetracker(args::NamedTuple) = (;args..., timetracker = TimeTracker())


# Check Progress
function progress(p::Process)
    loopidx(p) / maximum_loopidx(p)
end

"""
Gives an estimate of the remaining time for the process
"""
function est_remaining(p::Process)
    prog = progress(p)
    rt = runtime(p)
    total_time = rt / prog
    remaining_sec = total_time - rt
    total_hours = floor(Int, total_time / 3600)
    total_minutes = floor(Int, mod(total_time, 3600) / 60)
    total_seconds = floor(Int, mod(total_time, 60))
    hours = floor(Int, remaining_sec / 3600)
    minutes = floor(Int, mod(remaining_sec, 3600) / 60)
    seconds = floor(Int, mod(remaining_sec, 60))
    println("Estimated time to completion: $total_hours:$total_minutes:$total_seconds")
    println("Of which remaining: $hours:$minutes:$seconds")
end

function incs_per_sec(p::Process)
    loopidx(p) / runtime(p)
end

# CONDITIONAL PARTS
hasarg_exp = nothing
"""
Macro to easily do write conditional parts in algorithms to only execute
if a certain argument is present

This would commonly be used when an argument is passed in the creating of the process
This was a user can configure conditional parts in algorithms that only execute if a user passes
data with a certain name

Syntax is:

@hasarg if argname
    body
end

or

@hasarg if argname isa Type
    body
end
"""
macro hasarg(ex)
    argname = nothing
    body = nothing
    type = nothing
    condition = nothing 
    if @capture(ex, if argname_ isa type_ body_ end)
        condition = :(haskey(context, ($(QuoteNode(argname)))) && context.$argname isa $type)
    else @capture(ex, if argname_ body_ end)
        condition = :(haskey(context, ($(QuoteNode(argname)))))
    end

    
    body = MacroTools.postwalk(body) do x
        if x == argname
            return :(context.$argname)
        else
            return x
        end
    end
    global hasarg_exp = (quote
        Base.@assume_effects :foldable
        if $condition
            $(body)
        end
    end)
    return esc(hasarg_exp)
end
export @hasarg
