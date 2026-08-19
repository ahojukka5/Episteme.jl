# Test-only custom `Real`. Episteme must not special-case this type.
struct DualLike{T<:Real} <: Real
    value::T
    tangent::T
end

DualLike(value::Real, tangent::Real) = DualLike(promote(value, tangent)...)
Base.show(io::IO, x::DualLike) = print(io, "DualLike(", x.value, ", ", x.tangent, ")")

struct MaterialModel
    name::Symbol
    modulus::Float64
end

@testset "semantic nodes hold arbitrary Julia values" begin
    R = DualLike(1.4, 1.0)
    nested = DualLike(DualLike(1.4, 1.0), DualLike(0.0, 1.0))
    metric = [1.0 0.0; 0.0 1.0]
    eri = zeros(2, 2, 2, 2)
    model = MaterialModel(:steel, 210e9)
    payload = Dict(:x => 1)

    node = SemanticNode(
        :payload;
        R = R,
        nested = nested,
        metric = metric,
        eri = eri,
        model = model,
        extra = payload,
    )

    @test attribute(node, :R) === R
    @test attribute(node, :nested) === nested
    @test attribute(node, :metric) === metric
    @test attribute(node, :eri) === eri
    @test attribute(node, :model) === model
    @test attribute(node, :extra) === payload
    @test 2 * attribute(node, :R).value == 2.8

    shown = sprint(show, MIME"text/plain"(), node)
    @test occursin("DualLike", shown)
    @test occursin("MaterialModel", shown)
    @test occursin("Dict", shown)
    @test !occursin("ForwardDiff", shown)
    @test !isdefined(Episteme, :Differentiable)
    @test !isdefined(Episteme, :sexpr)
    @test :differentiable ∉ first.(node.attributes)
end
