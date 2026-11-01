
### SHOWING
abstract type IndentType end
struct Tab <: IndentType end
struct Dash <: IndentType end
struct VLine <: IndentType end

struct IndentIO{IOT, IT} <: IO
    io::IOT
    indent_type::IT
    indent::Int
    postfixes::Queue{String}
    next::Int
    # postfixes::Stack{String}
end

IndentIO(io, it::IndentType = VLine()) = IndentIO(io, it, 1, Queue{String}(), 0)
function NextIndentIO(io, it::IndentType = io.indent_type, prints...)
    if !isempty(prints)
        println(io, prints...)
    end
    if io isa IndentIO 
        return IndentIO(io.io, it, io.indent + io.next, Queue{String}(), 0)
    else
        return IndentIO(io, it, 0, Queue{String}(), 0)
    end
end
next(iio::IndentIO) = IndentIO(iio.io, iio.indent_type, iio.indent, iio.postfixes, iio.next +1)
# next(iio::IndentIO) = IndentIO(iio.io, iio.indent_type, iio.indent + 1, Queue{String}(), true)
q_postfix(iio::IndentIO, str) = enqueue!(iio.postfixes, str)
function q_postfixes(iio::IndentIO, strs...)
    for str in strs
        enqueue!(iio.postfixes, str)
    end
end

function getindent(num, ::Tab, extra = 0)
    "\t" ^ (num+extra)
end

function getindent(num, ::Dash, extra = 0)
    ("-" ^ (4*(num+extra)-1) ) * " "
end

function getindent(num, ::VLine, extra = 0)
    ("|" * "   ")^(num+extra)
end

getindent(io::IndentIO, extra = io.next) = getindent(io.indent, io.indent_type, extra)

function Base.show(io::IndentIO, args::Any...) # Fallback if it isn't defined
    println(io, args...)
end

# Revised Base.print and Base.println for IndentIO:
function Base.print(io::IndentIO, args...; extra = 0)
    # Join arguments and remove any trailing newline.
    text = chomp(join(args))
    # Split text by newline, but do not keep a trailing empty element.
    lines = split(text, '\n', keepempty=false)
    for (i, line) in enumerate(lines)
        # Use the first-line indent or subsequent-line indent.
        print(io.io, getindent(io, extra))
        # If a postfix is waiting, attach it.
        if !isempty(io.postfixes)
            print(io.io, line, dequeue!(io.postfixes))
        else
            print(io.io, line)
        end
    end
end

function Base.println(io::IndentIO, args...; extra = 0)
    text = chomp(join(args))
    lines = split(text, '\n', keepempty=false)
    for (i, line) in enumerate(lines)
        print(io.io, getindent(io))
        if !isempty(io.postfixes)
            println(io.io, line, dequeue!(io.postfixes))
        else
            println(io.io, line)
        end
    end
end