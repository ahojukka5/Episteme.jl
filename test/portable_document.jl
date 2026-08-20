# Portable declarative documents (#34). Live SemanticNode still accepts any value (#12).

struct PortableMaterial
    name::Symbol
    modulus::Float64
end

struct PortableBinding
    target::NodeRef
    scale::Float64
end

function Episteme.portable_encode(x::PortableMaterial)
    return (kind = Symbol("example/material"), data = (; name = x.name, modulus = x.modulus))
end

function Episteme.portable_decode(::Val{Symbol("example/material")}, data::NamedTuple)
    return PortableMaterial(data.name, data.modulus)
end

function Episteme.portable_encode(x::PortableBinding)
    return (kind = Symbol("example/binding"), data = (; target = x.target, scale = x.scale))
end

function Episteme.portable_decode(::Val{Symbol("example/binding")}, data::NamedTuple)
    return PortableBinding(data.target, data.scale)
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

@testset "portable metadata is fail-closed and canonical" begin
    model = SemanticNode(:ok, :root; n = 1)
    @test_throws ArgumentError capture_portable(
        DocumentId("doc-meta"),
        model;
        metadata = (; hook = identity),
    )
    doc = capture_portable(
        DocumentId("doc-meta"),
        model;
        metadata = (; note = "stable", tags = (:a, :b)),
    )
    @test doc.metadata.note == "stable"
    reloaded = from_namedtuple(PortableSemanticDocument, to_namedtuple(doc))
    @test reloaded.metadata == doc.metadata
end

@testset "PortableEncoded and PortableNode cannot smuggle runtime values" begin
    smuggled = PortableEncoded(Symbol("example/bad"), (; hook = identity))
    live = SemanticNode(:payload, :live; encoded = smuggled)
    @test !isvalid(validate_portable(live))
    @test_throws ArgumentError capture_portable(DocumentId("doc-smuggle"), live)

    node = PortableNode(
        :payload,
        :live,
        [:encoded => PortableEncoded(Symbol("example/bad"), (; hook = identity))],
        PortableNode[],
    )
    doc = PortableSemanticDocument(DocumentId("doc-smuggle"), [node])
    @test !isvalid(validate(doc))
    @test any(d -> d.code === :unsupported_portable_value, validate(doc).diagnostics)

    raw = PortableNode(:payload, :live, [:hook => identity], PortableNode[])
    @test !isvalid(validate(PortableSemanticDocument(DocumentId("doc-raw"), [raw])))
end

@testset "dicts restore as Dict and mixed keys have a total order" begin
    node = SemanticNode(:params, :p; values = Dict(:b => 2, :a => 1))
    doc = capture_portable(DocumentId("doc-dict"), node)
    @test attribute(restore_semantic(doc)[1], :values) == Dict(:a => 1, :b => 2)
    reloaded = from_namedtuple(PortableSemanticDocument, to_namedtuple(doc))
    @test attribute(restore_semantic(reloaded)[1], :values) == Dict(:a => 1, :b => 2)

    mixed_a = Dict{Any,Any}(:a => 1, "a" => 2)
    mixed_b = Dict{Any,Any}("a" => 2, :a => 1)
    da = capture_portable(DocumentId("doc-mix"), SemanticNode(:params, :p; values = mixed_a))
    db = capture_portable(DocumentId("doc-mix"), SemanticNode(:params, :p; values = mixed_b))
    @test to_namedtuple(da).fragments == to_namedtuple(db).fragments
    @test portable_sexpr(da) == portable_sexpr(db)
    restored = attribute(restore_semantic(da)[1], :values)
    @test restored[:a] == 1
    @test restored["a"] == 2
end

@testset "nested codec values restore and serialize recursively" begin
    node = SemanticNode(
        Symbol("example/part"),
        :beam;
        binding = PortableBinding(NodeRef(:plate), 2.0),
        bundle = (PortableMaterial(:steel, 210e9), NodeRef(:plate)),
    )
    doc = capture_portable(DocumentId("doc-nested"), node)
    generic = restore_semantic(doc; decode = false)
    @test attribute(generic[1], :binding) isa PortableEncoded
    bundle = attribute(generic[1], :bundle)
    @test bundle[1] isa PortableEncoded
    @test bundle[2] == NodeRef(:plate)

    decoded = restore_semantic(doc; decode = true)
    @test attribute(decoded[1], :binding) == PortableBinding(NodeRef(:plate), 2.0)
    decoded_bundle = attribute(decoded[1], :bundle)
    @test decoded_bundle[1] == PortableMaterial(:steel, 210e9)
    @test decoded_bundle[2] == NodeRef(:plate)

    nt = to_namedtuple(doc)
    binding_nt = nt.fragments[1].attributes[findfirst(a -> a.name === :binding, nt.fragments[1].attributes)].value
    @test binding_nt.portable_kind === :encoded
    @test binding_nt.data.portable_kind === :namedtuple
    reloaded = from_namedtuple(PortableSemanticDocument, nt)
    @test restore_semantic(reloaded; decode = true)[1] == decoded[1]
end
