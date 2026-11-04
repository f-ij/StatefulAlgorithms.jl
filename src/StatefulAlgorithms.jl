module StatefulAlgorithms
    const modulefolder = @__DIR__

    export getcontext, setcontext!, Process, start, quit

    using UUIDs, MacroTools, PrecompileTools
    using Base: setindex # previously re-exported by StaticArrays

    import Base: Threads.SpinLock, lock, unlock
    const wait_timeout = .5

    import DataStructures: Queue, dequeue!, enqueue!

    export StepAlgorithm, ProcessAlgorithm, AlgoState, ParserOption, IfWrapped, AbstractPlan, AbstractLoopAlgorithm, AbstractLoopCursor, LoopSpec, filter_by_type

    include("AbstractTypeDefs.jl")

    include("Utils.jl")
    include("Functions.jl")
    include("Unroll.jl")
    include("Printing.jl")
    include("ExpressionTools.jl")

    # include("Arena.jl")


    include("Processes/AbstractProcesses.jl")
    include("Lifetimes/Lifetimes.jl")
    include("Lifetimes/Hooks.jl")
    include("Lifetimes/Indefinite.jl")
    include("Lifetimes/Repeat.jl")
    include("Lifetimes/RepeatOnce.jl")
    include("Lifetimes/Until.jl")
    include("Lifetimes/AtLeast.jl")
    include("Lifetimes/RepeatOrUntil.jl")
    include("Lifetimes/AtLeastAtMost.jl")
    include("Sessions/Sessions.jl")
    include("Sessions/Interface.jl")
    include("Sessions/Hooks.jl")
    include("Processes/Interface.jl")
    include("Processes/Hooks.jl")
    include("ProcessEntities/ProcessEntities.jl")


    include("Matching.jl")
    include("Identifiable/Identifiable.jl")

    include("Registry/Registry.jl")
    # The general state (`@state`) is an algorithm state like the others in ProcessEntities/AlgoStates, but it needs
    # the matching and registry merge rules above.
    include("ProcessEntities/AlgoStates/GeneralState.jl")
    include("SubContextRefs.jl")

    include("RoutingInterface/RoutingInterface.jl")
    include("Context/Context.jl")
    include("Identifiable/Init.jl")
    include("Reports/Reports.jl")

    include("InputInterface/InputInterface.jl")
    include("Init.jl")
    include("ConstructorCommon.jl")
    # include("Running.jl")
    include("TriggerList.jl")
    include("Benchmark.jl")

    include("Processes/Construction.jl")
    include("Processes/Context.jl")
    include("Processes/Process/Process.jl")
    include("Processes/InlineProcess/InlineProcess.jl")



    include("Interactive/Interactive.jl")

    include("Widgets/Widgets.jl")


    include("Copy.jl")
    include("Manager/Manager.jl")
    include("PrecompileInterface.jl")

    include("LoopAlgorithms/LoopAlgorithms.jl")
    include("CompositeDSL/CompositeDSL.jl")
    include("Legacy/Legacy.jl")   # deprecated macros, removed in a later version
    include("ContextAnalyzer/ContextAnalyzer.jl")
    include("Inspection/Inspection.jl")
    include("Threaded/Threaded.jl")
    include("LoopAlgorithms/Edit/Edit.jl")
    include("Packaging/Packaging.jl")
    include("Context/Carried/Carried.jl")   # loops carry only the fields their steps write; after every node type it has a rule for
    include("Loops.jl")
    include("Trackers/Trackers.jl")
    include("TotalInc.jl")
    include("Tools.jl")
    include("Saving.jl")

    include("GeneratedCode/GeneratedCode.jl")
    include("Precompile.jl")

end
