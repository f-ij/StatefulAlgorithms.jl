# One code block a user might select and re-run. Evaluated by measure.jl phase by phase.
#=HANDLES=#
fast = Unique(Counter())
slow = Unique(Counter())
probe = Unique(Reader())
#=INNER=#
inner = @Routine begin
    @alias c = Counter
    x = c()
    probe(x = x)
end
#=COMP=#
comp = @CompositeAlgorithm begin
    @alias total = Adder
    @alias echo = Reader
    x = fast()
    total(a = x, b = x)
    x = @interval 2 slow()
    Watch(x = x)
    @context r = @interval 3 inner()
    echo()
    @route total.sum => echo.x
    Watch(@all(fast...))
end
#=RESOLVE=#
resolved = resolve(comp)
