# d7844

using Crayons
using Dates

# update to static in the future
mutable struct Piece{T<:Integer}
    shape::Matrix{T}
end

struct Board{T<:Integer}
    map::Matrix{T}  
end

# Describe the problem to solve
struct Problem{T<:Integer}
    pieces::Vector{Piece{T}}
    board::Board{T}
    optional::Board{T}  # mask of optional boundaries
end

# Contain all the solutions and stats. This is passed between branches
mutable struct Result
    total_placements::Int
    successful_placements::Int
    dead_ends::Int
    best_fit::Int  # best number of pieces fitted in the board
    best_times::Int  # number of times the best fit was achieved
    solutions::Vector{Board}
    tic::DateTime  # problem start time
    duration::Float64  # how long the problem took in milliseconds

    function Result()
        new(0, 0, 0, 1000, 0, Board[], now(), 0.0)
    end
end

# Hot Potato that is passed between branches and threads
mutable struct Potato
    reentractlocker::Threads.ReentrantLock  # To halt the threads while processing the callback
    threaded::Bool  # if multithreaded
    
    # Function to call (usually printing of some sort)
    # If multithreaded: (board::Board, potato::Potato, remaining:Vector{Piece})
    # Otherwise:        (board::Board, result::Result, remaining:Vector{Piece})
    func::Any

    # Method to call if a worker finishes a Problem. (Usually a subproblem when mutlithreaded)
    onfinish::Any   # (potato::Potato, problemindex::Int, result::Result)
    # Both methods are threadsafe and called while all threads are locked

    lasttime::Float64  # Last update
    dt::Float64  # Min time between updates
    tic::DateTime  # when we started solving all the problems

    # global variables that are combined across threads
    glo_total::Int
    glo_successfull::Int
    glo_numsols::Int
    glo_dead_ends::Int

    function Potato(;
            func=(w,x,y,z)->nothing,
            onfinish=(x,y,z)->nothing,
            dt=0.3,
            threaded=false
        )
        new(Threads.ReentrantLock(), threaded, func, onfinish, 0.0, dt, now(), 0, 0, 0, 0)
    end
end


warned = false

function string_map_to_matrix(map::String; key='1')::Matrix{Int64}
    lns = split(chomp(map), r"[;\n]")
    width = length(lns[1])
    for l in lns
        if length(l) !== length(lns[1])
            if !warned
                @warn "Piece/Board description is not rectangular... Automatically extending, but this could have unwanted effects."
                global warned = true
            end
            width = length(l)>width ? length(l) : width
        end
    end
    
    M = zeros(Int64, length(lns), width)
    for (j,l) in enumerate(lns)
        for (i,k) in enumerate(l)
            M[j,i] = k == key ? 1 : 0
        end
    end
    return M
end

# Constructors
newpiece(shp::Matrix{T}) where {T<:Integer} = Piece(shp)
newpiece(p::Piece) = Piece(copy(p.shape))
newpiece(map::String) = newpiece(map, 1)
newpiece(map::String, id::Integer) = newpiece(string_map_to_matrix(map) .* id)

newboard(shp::Matrix{T}) where {T<:Integer} = Board(shp)
newboard(b::Board) = Board(copy(b.map))  # is a copy
newboard(map::String) = newboard(string_map_to_matrix(map) * INVALID_BOARD)

newproblem(p::Vector{Piece{T}}, b::Board{T}) where {T<:Integer} = Problem(p, b, newboard(zeros(eltype(b.map), size(b))))
newproblem(p::Vector{Piece{T}}, b::Board{T}, m::Board{T}) where {T<:Integer} = Problem(p, b, m)

Base.:(==)(p::Piece, q::Piece) = p.shape == q.shape
Base.:(==)(b::Board, bb::Board) = b.map == bb.map

# useful to overload Base.size
Base.size(p::Piece) = size(p.shape)
Base.size(b::Board) = size(b.map)
Base.size(b::Board, d::T) where {T<:Integer} = size(b)[d]

# Overload printing methods
const colormap = repeat(
    [crayon"bg:(0,0,0)",
    crayon"bg:(230,25,75)",
    crayon"bg:(60,180,75)",
    crayon"bg:(255,255,25)",
    crayon"bg:(0,130,200)",
    crayon"bg:(245,130,48)",
    crayon"bg:(145,30,180)",
    crayon"bg:(70,240,240)",
    crayon"bg:(240,50,230)",
    crayon"bg:(250,190,212)",
    crayon"bg:(0,128,128)",
    crayon"bg:(220,190,255)",
    crayon"bg:(170,110,40)",
    Crayon(background=:default)
    ], 2)

function print_color_matrix(io::IO, M::AbstractArray)
    s = "\n"
    for l in 1:size(M, 1)
        s *= join(map(x->colormap[x+1]("  "), M[l,:])) * "\n"
    end
    print(io, chomp(s))
end

function Base.show(io::IO, b::Board)  # use colours
    print_color_matrix(io, b.map) 
end

function Base.show(io::IO, p::Piece)
    s = "\n"
    for l in 1:size(p.shape, 1)
        s *= join(map(x->colormap[x+1]("  "), p.shape[l,:])) * "\n"
    end
    print(io, chomp(s))
end

function Base.show(io::IO, prob::Problem)
    println(io, "Lonpos problem with $(typeof(prob.board)),", prob.board)
    println(io, "optional cells of,", newboard(prob.board.map + prob.optional.map))

    maxwidth = displaysize(stdout)[2] ÷ 2  # division as each pixel is "  "
    i = 0
    height = 0

    print(io, "And $(typeof(prob.pieces[1])) ")
    
    toprint = Piece[]
    for p in prob.pieces 
        if i + size(p.shape, 2) + 1 >= maxwidth # flush the pieces
            M = ones(Integer, height, i) * INVALID_BOARD
            inx = 1
            for p in toprint  # know the size is correct
                M[1:size(p.shape,1), inx:size(p.shape,2)+inx-1] = p.shape
                inx += size(p.shape,2) + 1
            end
            print_color_matrix(io, M)
            i = 0
            toprint = Piece[]
            height = 0
        end
        # Add the piece to the stack
        i += size(p.shape, 2) + 1
        height = size(p.shape,1)>height ? size(p.shape,1) : height
        push!(toprint, p)
    end
    # convert to a matrix and print that like the board
    M = ones(Integer, height, i) * INVALID_BOARD
    inx = 1
    for p in toprint  # know the size is correct
        M[1:size(p.shape,1), inx:size(p.shape,2)+inx-1] = p.shape
        inx += size(p.shape,2) + 1
    end
    print_color_matrix(io, M)
end

function Base.show(io::IO, result::Result)
    print(io, "Result with $(length(result.solutions)) solutions. Placed $(result.total_placements) pieces total, with $(result.successful_placements) being successful")
end