module StatefulAlgorithms
    const modulefolder = @__DIR__

    export getcontext, context, Process, start, quit

    using UUIDs, Preferences, MacroTools, PrecompileTools
    using Base: setindex # previously re-exported by StaticArrays

    import Base: Threads.SpinLock, lock, unlock
    const wait_timeout = .5

    import DataStructures: Queue, dequeue!, enqueue!

    export StepAlgorithm, ProcessAlgorithm, AlgoState, ParserOption, IfWrapped, AbstractPlan, AbstractLoopAlgorithm, AbstractLoopCursor, LoopSpec, filter_by_type

    const DEBUG_MODE = @load_preference("debug", false)
    debug_mode() = @load_preference("debug", false)
    function debug_mode(bool)
        @set_preferences!("debug" => bool)
    end

    include("AbstractTypeDefs.jl")

    include("Utils.jl")
    include("Functions.jl")
    include("Unroll.jl")
    include("Printing.jl")
    include("ExpressionTools.jl")

    # include("Arena.jl")


    include("AbstractProcesses/AbstractProcesses.jl")
    include("Lifetimes/Lifetimes.jl")
    include("Lifetimes/Hooks.jl")
    include("Lifetimes/HookExtensions.jl")
    include("Sessions/Sessions.jl")
    include("Sessions/Interface.jl")
    include("Sessions/Hooks.jl")
    include("Sessions/InlineSession.jl")
    include("Sessions/InteractiveSession.jl")
    include("Sessions/HookExtensions.jl")
    include("AbstractProcesses/Interface.jl")
    include("ProcessEntities/ProcessEntities.jl")


    include("Matching.jl")
    include("Identifiable/Identifiable.jl")

    include("Registry/Registry.jl")
    # The general state (`@state`) is an algorithm state like the others in ProcessEntities/AlgoStates, but it needs
    # the matching and registry merge rules above.
    include("ProcessEntities/AlgoStates/GeneralState.jl")
    include("SubContextRefs.jl")
    include("Identifiable/UniquePlanId/UniqueKeyMap.jl")
    include("Identifiable/UniquePlanId/HookExtensions.jl")

    include("RoutingInterface/RoutingInterface.jl")
    include("Context/Context.jl")
    include("Identifiable/UniquePlanId/ContextKeymap.jl")
    include("Identifiable/Init.jl")
    include("Reports/Reports.jl")

    include("InputInterface/InputInterface.jl")
    include("Init.jl")
    include("ConstructorCommon.jl")
    # include("Running.jl")
    include("TriggerList.jl")
    include("Benchmark.jl")
    include("Debugging.jl")
    include("Listeners.jl")

    include("Process.jl")
    include("ProcessPrecompile.jl")
    include("InlineProcess.jl")
    include("InlineProcessShowing.jl")


    include("ProcessList.jl")

    include("Interactive/Interactive.jl")

    include("Widgets/Widgets.jl")


    include("ProcessStatus.jl")
    include("ProcessInteraction.jl")
    include("Copy.jl")
    include("Manager/Manager.jl")

    include("LoopAlgorithms/LoopAlgorithms.jl")
    include("CompositeDSL/CompositeDSL.jl")
    include("Legacy/Legacy.jl")   # deprecated macros, removed in a later version
    include("ContextAnalyzer/ContextAnalyzer.jl")
    include("Inspection/Inspection.jl")
    include("Threaded/Threaded.jl")
    include("LoopAlgorithms/Edit/Edit.jl")
    include("Packaging/Packaging.jl")
    include("Loops.jl")
    include("Trackers/Trackers.jl")
    include("TotalInc.jl")
    include("Tools.jl")
    include("Saving.jl")

    include("GeneratedCode/GeneratedCode.jl")
    include("Precompile.jl")

end
