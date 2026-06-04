[![Docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://f-ij.github.io/StatefulAlgorithms.jl/stable/)

# StatefulAlgorithms.jl

StatefulAlgorithms.jl helps you build repeatable Julia loops from small pieces.

Each piece is a `ProcessAlgorithm` with a `step!` method, or a `ProcessState`
that prepares shared data. A `Process` builds a context for those pieces, runs
the loop, and keeps the latest state so you can pause, resume, inspect, copy, or
update it.

Start with the [documentation](https://f-ij.github.io/StatefulAlgorithms.jl/stable/).
