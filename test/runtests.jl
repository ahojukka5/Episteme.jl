using Test
using Episteme

struct DummyObject end

@testset "Episteme.jl" begin

    @testset "package loads" begin
        @test isdefined(Main, :Episteme)
    end

    @testset "generic functions exist" begin
        @test isdefined(Episteme, :report)
        @test isdefined(Episteme, :validate)
        @test isdefined(Episteme, :readiness)
        @test isdefined(Episteme, :AbstractEpistemeReport)
        @test !isdefined(Episteme, :AbstractOodiReport)
        @test !isdefined(Episteme, :OodiCore)
    end

    @testset "diagnostic constructors" begin
        i = info_diagnostic(:ok, "Everything is fine")
        @test i isa Episteme.DiagnosticMessage
        @test i.severity == :info
        @test i.code == :ok
        @test i.message == "Everything is fine"

        w = warning_diagnostic(:fragile, "This may be fragile"; hint = "check tolerances")
        @test w.severity == :warning
        @test w.context.hint == "check tolerances"

        e = error_diagnostic(:failed, "Something failed")
        @test e.severity == :error

        @test !isdefined(@__MODULE__, :info)
        @test !isdefined(@__MODULE__, :warning)
        @test isdefined(@__MODULE__, :info_diagnostic)
        @test isdefined(@__MODULE__, :warning_diagnostic)

        @test_throws ErrorException Episteme._diagnostic(:bogus, :x, "nope")
    end

    @testset "PipelineTarget" begin
        t = PipelineTarget(:meshing)
        @test t.name == :meshing
        @test t.options == (;)

        t2 = PipelineTarget(:gmg; levels = 3)
        @test t2.options.levels == 3
    end

    @testset "ArtifactRef" begin
        a = ArtifactRef(:png; path = "preview.png", description = "preview image")
        @test a.kind == :png
        @test a.path == "preview.png"
        @test a.uri === nothing
    end

    @testset "ValidationReport" begin
        r = ValidationReport(:mesh, false, [error_diagnostic(:missing_boundary_tag, "Required boundary tag :fixed_support was not found.")], (;))
        @test isvalid(r) == false
        @test r.subject == :mesh
        @test length(r.diagnostics) == 1
    end

    @testset "ReadinessReport" begin
        target = PipelineTarget(:gmg)
        r = ReadinessReport(:mesh_hierarchy, target, false, [error_diagnostic(:missing_transfers, "Parent-node transfer data is unavailable.")], (;))
        @test isready(r) == false
        @test r.target === target
    end

    @testset "ObjectReport" begin
        r = ObjectReport(:mesh, "3D Tet4 mesh with 12420 elements and 2841 nodes.", (; nelements = 12420), DiagnosticMessage[], ArtifactRef[])
        @test r.subject == :mesh
        @test r.summary != ""
    end

    @testset "to_namedtuple" begin
        d = info_diagnostic(:ok, "fine")
        nt = to_namedtuple(d)
        @test nt.severity == :info
        @test nt.code == :ok

        t = PipelineTarget(:meshing)
        @test to_namedtuple(t).name == :meshing

        a = ArtifactRef(:vtk; path = "mesh.vtk")
        @test to_namedtuple(a).kind == :vtk

        vr = ValidationReport(:mesh, true, DiagnosticMessage[], (;))
        @test to_namedtuple(vr).valid == true

        rr = ReadinessReport(:mesh, t, true, DiagnosticMessage[], (;))
        ntr = to_namedtuple(rr)
        @test ntr.ready == true
        @test ntr.target.name == :meshing

        orpt = ObjectReport(:mesh, "summary", (;), DiagnosticMessage[], ArtifactRef[])
        @test to_namedtuple(orpt).summary == "summary"
    end

    @testset "show methods produce readable output" begin
        vr = ValidationReport(:mesh, false, [error_diagnostic(:missing_boundary_tag, "Required boundary tag :fixed_support was not found.")], (;))
        s = sprint(show, vr)
        @test occursin("ValidationReport", s)
        @test occursin("missing_boundary_tag", s)

        target = PipelineTarget(:gmg)
        rr = ReadinessReport(:mesh_hierarchy, target, false, [error_diagnostic(:missing_transfers, "Parent-node transfer data is unavailable.")], (;))
        s2 = sprint(show, rr)
        @test occursin("ReadinessReport", s2)
        @test occursin("missing_transfers", s2)

        orpt = ObjectReport(:mesh, "3D Tet4 mesh with 12420 elements and 2841 nodes.", (;), [warning_diagnostic(:low_quality_elements, "14 elements have quality below threshold.")], ArtifactRef[])
        s3 = sprint(show, orpt)
        @test occursin("ObjectReport", s3)
        @test occursin("low_quality_elements", s3)

        d = error_diagnostic(:failed, "Something failed")
        s4 = sprint(show, MIME"text/plain"(), d)
        @test occursin("failed", s4)
    end

    @testset "downstream-style extension" begin
        report(::DummyObject) = ObjectReport(
            :dummy,
            "dummy object",
            (;),
            DiagnosticMessage[],
            ArtifactRef[],
        )

        validate(::DummyObject) = ValidationReport(
            :dummy,
            true,
            DiagnosticMessage[],
            (;),
        )

        readiness(::DummyObject, target::PipelineTarget) = ReadinessReport(
            :dummy,
            target,
            true,
            DiagnosticMessage[],
            (;),
        )

        obj = DummyObject()

        rep = report(obj)
        @test rep isa ObjectReport
        @test rep.subject == :dummy

        val = validate(obj)
        @test val isa ValidationReport
        @test isvalid(val)

        rdy = readiness(obj, PipelineTarget(:meshing))
        @test rdy isa ReadinessReport
        @test isready(rdy)
    end

    @testset "generic semantic tree" begin
        plate = SemanticNode(
            Symbol("monge/rectangle"),
            :plate;
            width = 10.0,
            height = 5.0,
        )
        block = SemanticNode(
            Symbol("monge/extrude"),
            :block;
            profile = NodeRef(:plate),
            distance = 3.0,
        )
        model = SemanticNode(:geometry, :demo)

        @test add_child!(model, plate) === model
        @test push!(model, block) === model
        @test model.children == [plate, block]

        @test attribute(plate, :width) == 10.0
        @test attribute(plate, :missing, :default) == :default
        @test_throws KeyError attribute(plate, :missing)

        @test set_attribute!(plate, :width, 20.0) === plate
        @test attribute(plate, :width) == 20.0

        equivalent_plate = SemanticNode(
            Symbol("monge/rectangle"),
            :plate;
            height = 5.0,
            width = 20.0,
        )
        @test plate == equivalent_plate
        @test NodeRef("plate") == NodeRef(:plate)

        point = SemanticNode(:point, :origin; coordinates = (0.0, 0.0, 0.0))
        @test attribute(point, :coordinates) == (0.0, 0.0, 0.0)

        shown = sprint(show, MIME"text/plain"(), model)
        @test occursin("SemanticNode(:geometry, :demo)", shown)
        @test occursin("width = 20.0", shown)
        @test occursin("NodeRef(:plate)", shown)
        @test !isdefined(Episteme, :sexpr)
    end

    include("semantic_values.jl")

    include("declarative.jl")

    include("archive_envelope.jl")
    include("archive_history.jl")
    include("archive_revision_dag.jl")
    include("archive_lifecycle.jl")
end
