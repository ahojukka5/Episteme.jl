# Portable declarative documents (#34). Live SemanticNode still accepts any value (#12).

struct PortableMaterial
    name::Symbol
    modulus::Float64
end

function Episteme.portable_encode(x::PortableMaterial)
    return (kind = Symbol("example/material"), data = (; name = x.name, modulus = x.modulus))
end

function Episteme.portable_decode(::Val{Symbol("example/material")}, data::NamedTuple)
    return PortableMaterial(data.name, data.modulus)
end

function _example_geometry()
    plate = SemanticNode(
        Symbol("example/rectangle"),
        :plate;
        width = 10.0,
        height = 5.0,
    )
    block = SemanticNode(
        Symbol("example/extrude"),
        :block;
        profile = NodeRef(:plate),
        distance = 3.0,
        tags = (:load, :support),
        origin = (0.0, 0.0),
    )
    model = SemanticNode(Symbol("example/geometry"), :demo)
    push!(model, plate)
    push!(model, block)
    return model
end

@testset "portable document round-trips node and reference content" begin
    model = _example_geometry()
    @test isvalid(validate_portable(model))
    doc = capture_portable(DocumentId("doc-1"), model)
    @test doc.id == DocumentId("doc-1")
    @test schema_kind(doc.schema) === EPISTEME_DOCUMENT_KIND
    @test isvalid(validate(doc))
    restored = restore_semantic(doc)
    @test length(restored) == 1
    @test restored[1] == model
    @test attribute(restored[1].children[2], :profile) == NodeRef(:plate)

    nt = to_namedtuple(doc)
    reloaded = from_namedtuple(PortableSemanticDocument, nt)
    @test reloaded == doc
    @test restore_semantic(reloaded)[1] == model
    @test !isdefined(Episteme, :sexpr)
    @test :PortableSemanticDocument in names(Episteme)
    @test occursin("episteme/document", portable_sexpr(doc))
    @test occursin("(ref plate)", portable_sexpr(doc))
    @test report(doc).metadata.fragments == 1
    plan = Plan(PlanId("plan-1"); document_id = doc.id)
    @test plan.document_id == doc.id
end

@testset "unsupported live values stay legal in SemanticNode but fail capture" begin
    dual = DualLike(1.4, 1.0)
    model = MaterialModel(:steel, 210e9)
    live = SemanticNode(:payload, :live; dual = dual, model = model, extra = Dict(:x => 1))
    @test attribute(live, :dual) === dual
    @test attribute(live, :model) === model
    report = validate_portable(live)
    @test !isvalid(report)
    @test any(d -> d.code === :unsupported_portable_value && d.context.attribute === :dual, report.diagnostics)
    @test any(d -> d.context.attribute === :model, report.diagnostics)
    @test_throws ArgumentError capture_portable(DocumentId("doc-bad"), live)
    @test !is_portable_value(dual)
    @test is_portable_value(1.4)
    @test is_portable_value(NodeRef(:plate))
end

@testset "registered portable codec round-trips without eval" begin
    node = SemanticNode(
        Symbol("example/part"),
        :beam;
        material = PortableMaterial(:steel, 210e9),
        area = 2.0,
    )
    @test isvalid(validate_portable(node))
    doc = capture_portable(DocumentId("doc-mat"), node)
    encoded = last(doc.fragments[1].attributes[findfirst(p -> first(p) === :material, doc.fragments[1].attributes)])
    @test encoded isa PortableEncoded
    @test encoded.kind === Symbol("example/material")
    generic = restore_semantic(doc; decode = false)
    @test attribute(generic[1], :material) isa PortableEncoded
    decoded = restore_semantic(doc; decode = true)
    @test attribute(decoded[1], :material) == PortableMaterial(:steel, 210e9)
    sexpr = portable_sexpr(doc)
    @test occursin("example/material", sexpr)
    @test !occursin("eval", sexpr)
end

@testset "canonical portable form is independent of dict insertion order" begin
    a = SemanticNode(:params, :p; values = Dict(:b => 2, :a => 1, :c => 3))
    b = SemanticNode(:params, :p; values = Dict(:c => 3, :a => 1, :b => 2))
    da = capture_portable(DocumentId("doc-a"), a)
    db = capture_portable(DocumentId("doc-a"), b)
    @test to_namedtuple(da).fragments == to_namedtuple(db).fragments
    @test portable_sexpr(da) == portable_sexpr(db)
    metric = SemanticNode(:tensor, :g; metric = [1.0 0.0; 0.0 1.0])
    captured = capture_portable(DocumentId("doc-t"), metric)
    restored = restore_semantic(captured)[1]
    @test attribute(restored, :metric) == [1.0 0.0; 0.0 1.0]
end

@testset "portable capture diagnostics name the node and attribute" begin
    nested = SemanticNode(Symbol("example/child"), :child; hook = identity)
    root = SemanticNode(Symbol("example/root"), :root)
    push!(root, nested)
    report = validate_portable(root)
    @test !isvalid(report)
    diag = only(report.diagnostics)
    @test diag.code === :unsupported_portable_value
    @test diag.context.node == "root/child"
    @test diag.context.attribute === :hook
    @test_throws ArgumentError capture_portable(
        DocumentId("doc-1"),
        root;
        schema = SchemaRef(:example, "other", "1.0.0"),
    )
end
