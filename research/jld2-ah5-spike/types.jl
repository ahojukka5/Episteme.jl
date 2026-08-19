# Representative domain-owned types for the spike. These stand in for
# independently owned payloads; they are not real domain packages.

module GeometrySpike

export Box, DualLike

struct Box
    width::Float64
    depth::Float64
    height::Float64
end

# Custom numeric leaf that SemanticNode must store unchanged (#12).
struct DualLike <: Real
    value::Float64
    partial::Float64
end

Base.promote_rule(::Type{DualLike}, ::Type{Float64}) = DualLike
Base.:+(a::DualLike, b::DualLike) = DualLike(a.value + b.value, a.partial + b.partial)

end # module

module DomainSpike

export ModelState, ModelStateV2, Status, idle, running, done

@enum Status begin
    idle = 1
    running = 2
    done = 3
end

struct ModelState
    sites::Int
    particles::Int
    Sz::Int
end

# v2 used only in the type-evolution experiment.
struct ModelStateV2
    sites::Int
    particles::Int
    Sz::Float64
    nup::Int
end

end # module

mutable struct Counter
    n::Int
end

struct Mesh{T}
    coords::Matrix{T}
    connectivity::Matrix{Int}
end

mutable struct CycleNode
    name::String
    other::Union{Nothing,CycleNode}
end
