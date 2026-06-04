push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))

using Documenter
using StatefulAlgorithms

Base.include(StatefulAlgorithms, joinpath(@__DIR__, "..", "src", "ContextAnalyzer", "ContextAnalyzer.jl"))

makedocs(
    modules = [StatefulAlgorithms],
    checkdocs = :none,
    sitename = "StatefulAlgorithms",
    format = Documenter.HTML(),
    pages = [
        "Home" => "index.md",
        "User Documentation" => [
            "Algorithms and States" => "user/algorithms_states.md",
            "Composite DSL" => "user/composite_dsl.md",
            "Referencing Algorithms" => "user/referencing_algorithms.md",
            "Contexts and Indexing" => "user/contexts.md",
            "Init Analysis" => "user/init_analysis.md",
            "Routes and Shares" => "user/routes_shares.md",
            "Init, Overrides, and Runtime Inputs" => "user/inputs_overrides.md",
            "Vars (Var Selectors)" => "user/vars.md",
            "Interactive Contexts" => "user/interactive.md",
            "Lifetime" => "user/lifetime.md",
            "Running, Wait, Fetch" => "user/running.md",
            "Copying Processes" => "user/copying_and_management.md",
            "Threaded Process Managers" => "user/threaded_process_managers.md",
            "Value Semantics and Unique" => "user/value_semantics.md",
        ],
        "Internals" => [
            "Registry" => "internals/registry.md",
            "Contexts" => "internals/contexts.md",
            "Routes and Shares" => "internals/routes_shares.md",
            "Process Pipeline" => "internals/process_pipeline.md",
        ],
    ],
)

deploydocs(
    repo = "github.com/f-ij/StatefulAlgorithms.jl.git",
    devbranch = "main",
    versions = ["stable" => "dev", "dev" => "dev"],
)
