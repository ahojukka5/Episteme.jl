# Logical archive envelope (#26). These tests must not require HDF5.

function _ns(id::Symbol; uuid = "", display = "")
    return ArchiveNamespace(id; package_uuid = uuid, display_name = display)
end

function _obj(
    namespace::Symbol,
    schema_id::AbstractString,
    object::AbstractString,
    revision::AbstractString;
    version = "1.0.0",
    extras = (;),
    references = ArchiveReference[],
    content = nothing,
    run = nothing,
    provenance = ProvenanceRefs(),
    uuid = "",
)
    ns = _ns(namespace; uuid = uuid, display = String(namespace) * ".jl")
    kind = schema_kind(namespace, schema_id)
    return ArchiveObject(
        ObjectId(object),
        RevisionId(revision);
        content_id = content === nothing ? nothing : ContentId(content),
        run_id = run === nothing ? nothing : RunId(run),
        namespace = ns,
        kind = kind,
        schema = SchemaRef(namespace, schema_id, version),
        provenance = provenance,
        references = references,
        extras = extras,
    )
end

@testset "archive identities are distinct types" begin
    object = ObjectId("same-bytes")
    revision = RevisionId("same-bytes")
    content = ContentId("same-bytes")
    head = WorkflowHeadId("same-bytes")

    @test object isa AbstractArchiveId
    @test object != revision
    @test object != content
    @test revision != content
    @test object != head
    @test object.value == content.value
    @test string(object) == "same-bytes"
    @test ObjectId("same-bytes") == object
    @test isless(ObjectId("a"), ObjectId("b"))

    @test_throws ArgumentError ObjectId("")
    @test_throws ArgumentError ObjectId("   ")
    @test_throws ArgumentError RevisionId("")
    @test_throws ArgumentError ContentId("")
    @test_throws ArgumentError SchemaRef(:oodi, "", "1.0.0")
    @test_throws ArgumentError SchemaRef(:oodi, "field", "  ")
end

@testset "logical scalar and array conventions" begin
    length_m = LogicalType(:real; units = "m", frame = "box")
    @test length_m.kind == :real
    @test length_m.units == "m"
    @test length_m.frame == "box"

    status = LogicalType(:enum; enum_values = (:open, :closed))
    @test status.enum_values == (:open, :closed)
    @test_throws ArgumentError LogicalType(:enum)
    @test_throws ArgumentError LogicalType(:real; enum_values = (:x,))
    @test_throws ArgumentError LogicalType(:mesh)

    coords = LogicalArraySpec(:coordinates, length_m, 2; shape = (3, nothing))
    @test coords.rank == 2
    @test coords.shape == (3, nothing)
    @test_throws ArgumentError LogicalArraySpec(:coordinates, length_m, 2; shape = (3,))
    @test_throws ArgumentError LogicalArraySpec(:coordinates, length_m, -1)
end

@testset "schema version rules do not infer compatibility" begin
    v1 = SchemaRef(:oodi, "field", "1.0.0")
    v2 = SchemaRef(:oodi, "field", "2.0.0")
    @test schema_kind(v1) === Symbol("oodi/field")
    @test v1 != v2

    catalog = ArchiveCatalog(;
        schemas = [
            KnownSchema(v1, :exact_read),
            KnownSchema(v2, :migration_required),
            KnownSchema(SchemaRef(:delone, "mesh", "0.9.0"), :unsupported),
        ],
        software_environments = [SoftwareEnvironmentId("env-1")],
        execution_contexts = [ExecutionContextId("ctx-1")],
    )

    @test schema_status(v1, catalog) === :exact_read
    @test schema_status(v2, catalog) === :migration_required
    @test schema_status(SchemaRef(:oodi, "field", "1.1.0"), catalog) === :missing_schema
    @test schema_status(SchemaRef(:delone, "mesh", "0.9.0"), catalog) === :unsupported
    @test resolve_schema(SchemaRef(:lieb, "sector", "1.0.0"), catalog) === nothing
    @test_throws ArgumentError KnownSchema(v1, :probably_fine)
end

@testset "package extras stay package-owned" begin
    field = _obj(
        :oodi,
        "field",
        "field-1",
        "rev-field";
        extras = (; values = :package_owned, association = :node),
    )
    @test field.extras.values === :package_owned
    @test !hasfield(typeof(field), :values)
    nt = to_namedtuple(field)
    @test nt.extras.values === :package_owned
    @test nt.kind === Symbol("oodi/field")
end

@testset "geometry to field graph plus sibling-domain objects" begin
    geometry = _obj(
        :monge,
        "box",
        "geom-1",
        "rev-geom";
        extras = (; width = 0.4, depth = 0.5, height = 2.0),
    )
    mesh = _obj(
        :delone,
        "mesh",
        "mesh-1",
        "rev-mesh";
        references = [ArchiveReference(:geometry, geometry.object_id; revision_id = geometry.revision_id)],
        extras = (; nelements = 12),
        provenance = ProvenanceRefs(; producer_revision = geometry.revision_id),
    )
    space = _obj(
        :oodi,
        "space",
        "space-1",
        "rev-space";
        references = [ArchiveReference(:mesh, mesh.object_id; revision_id = mesh.revision_id)],
        extras = (; basis = :lagrange),
        provenance = ProvenanceRefs(;
            software_environment = SoftwareEnvironmentId("env-1"),
            execution_context = ExecutionContextId("ctx-1"),
            producer_revision = mesh.revision_id,
        ),
    )
    field = _obj(
        :oodi,
        "field",
        "field-1",
        "rev-field";
        content = "hash-u",
        run = "run-1",
        references = [ArchiveReference(:space, space.object_id; revision_id = space.revision_id)],
        extras = (; association = :node),
        provenance = ProvenanceRefs(; producer_revision = space.revision_id),
    )
    posterior = _obj(
        :stinespring,
        "posterior",
        "post-1",
        "rev-post";
        extras = (; draws = 128),
    )
    sector = _obj(
        :lieb,
        "hubbard-sector",
        "sector-1",
        "rev-sector";
        extras = (; particles = 6, sites = 8),
    )
    model = _obj(
        :chappe,
        "model",
        "model-1",
        "rev-model";
        extras = (; family = :moe),
    )

    # Same logical content may be reused without sharing object identity.
    field_copy = _obj(
        :oodi,
        "field",
        "field-alias",
        "rev-alias";
        content = "hash-u",
        extras = (; association = :node),
    )
    @test field.content_id == field_copy.content_id
    @test field.object_id != field_copy.object_id
    @test field.revision_id != field_copy.revision_id

    head = WorkflowHead(WorkflowHeadId("head-main"), :main, field.revision_id)
    graph = ArchiveGraph(
        [field, sector, geometry, posterior, space, mesh, model, field_copy];
        heads = [head],
    )

    @test isvalid(validate(geometry))
    @test isvalid(validate(graph))

    catalog = ArchiveCatalog(;
        schemas = [
            KnownSchema(geometry.schema, :exact_read),
            KnownSchema(mesh.schema, :exact_read),
            KnownSchema(space.schema, :backwards_compatible),
            KnownSchema(field.schema, :exact_read),
            KnownSchema(posterior.schema, :exact_read),
            KnownSchema(sector.schema, :exact_read),
            KnownSchema(model.schema, :exact_read),
        ],
        software_environments = [SoftwareEnvironmentId("env-1")],
        execution_contexts = [ExecutionContextId("ctx-1")],
    )
    @test isvalid(validate(graph, catalog))
    @test schema_status(space.schema, catalog) === :backwards_compatible

    ordered = ordered_objects(graph)
    @test [obj.namespace.id for obj in ordered] ==
        [:chappe, :delone, :lieb, :monge, :oodi, :oodi, :oodi, :stinespring]
    @test ordered != graph.objects

    @test find_object(graph, mesh.object_id, mesh.revision_id) === mesh
    @test find_revisions(graph, field.object_id) == [field]

    appended = ArchiveGraph(vcat(graph.objects, [_obj(:sorby, "volume", "vol-1", "rev-vol")]))
    @test isvalid(validate(appended))
    @test find_object(appended, mesh.object_id, mesh.revision_id).references[1].target.object_id ==
        geometry.object_id

    rep = report(field)
    @test rep.subject === Symbol("oodi/field")
    @test occursin("field-1", rep.summary)
    @test sprint(show, graph) == "ArchiveGraph(objects=8, heads=1)"
end

@testset "dangling and incompatible metadata fail explicitly" begin
    geometry = _obj(:monge, "box", "geom-1", "rev-geom")
    mesh = _obj(
        :delone,
        "mesh",
        "mesh-1",
        "rev-mesh";
        references = [ArchiveReference(:geometry, ObjectId("missing-geom"))],
    )
    dangling = validate(ArchiveGraph([geometry, mesh]))
    @test !isvalid(dangling)
    @test any(d -> d.code === :dangling_reference, dangling.diagnostics)

    pinned_missing = _obj(
        :delone,
        "mesh",
        "mesh-2",
        "rev-mesh-2";
        references = [ArchiveReference(
            :geometry,
            geometry.object_id;
            revision_id = RevisionId("rev-absent"),
        )],
    )
    pinned = validate(ArchiveGraph([geometry, pinned_missing]))
    @test !isvalid(pinned)
    @test any(d -> d.code === :dangling_reference, pinned.diagnostics)

    producer = _obj(
        :oodi,
        "field",
        "field-1",
        "rev-field";
        provenance = ProvenanceRefs(; producer_revision = RevisionId("rev-ghost")),
    )
    @test any(
        d -> d.code === :dangling_producer_revision,
        validate(ArchiveGraph([producer])).diagnostics,
    )

    head = WorkflowHead(WorkflowHeadId("head-1"), :main, RevisionId("rev-ghost"))
    @test any(
        d -> d.code === :dangling_workflow_head,
        validate(ArchiveGraph([geometry]; heads = [head])).diagnostics,
    )

    mismatched = ArchiveObject(
        ObjectId("x"),
        RevisionId("r");
        namespace = _ns(:oodi),
        kind = Symbol("delone/mesh"),
        schema = SchemaRef(:monge, "box", "1.0.0"),
    )
    local_report = validate(mismatched)
    @test !isvalid(local_report)
    codes = Set(d.code for d in local_report.diagnostics)
    @test :kind_namespace_mismatch in codes
    @test :schema_namespace_mismatch in codes
    @test :schema_kind_mismatch in codes

    catalog = ArchiveCatalog(;
        schemas = [
            KnownSchema(SchemaRef(:oodi, "field", "1.0.0"), :exact_read),
            KnownSchema(SchemaRef(:oodi, "field", "0.9.0"), :unsupported),
            KnownSchema(SchemaRef(:oodi, "field", "0.8.0"), :migration_required),
        ],
        software_environments = SoftwareEnvironmentId[],
        execution_contexts = ExecutionContextId[],
    )
    current = _obj(:oodi, "field", "f1", "r1")
    @test isvalid(validate(current, catalog))

    missing = _obj(:oodi, "field", "f2", "r2"; version = "3.0.0")
    @test any(d -> d.code === :missing_schema, validate(missing, catalog).diagnostics)

    old = _obj(:oodi, "field", "f3", "r3"; version = "0.9.0")
    @test any(d -> d.code === :unsupported_schema, validate(old, catalog).diagnostics)

    migrate = _obj(:oodi, "field", "f4", "r4"; version = "0.8.0")
    @test any(d -> d.code === :migration_required, validate(migrate, catalog).diagnostics)

    env_obj = _obj(
        :oodi,
        "field",
        "f5",
        "r5";
        provenance = ProvenanceRefs(;
            software_environment = SoftwareEnvironmentId("env-missing"),
            execution_context = ExecutionContextId("ctx-missing"),
        ),
    )
    env_report = validate(env_obj, catalog)
    env_codes = Set(d.code for d in env_report.diagnostics)
    @test :missing_software_environment in env_codes
    @test :missing_execution_context in env_codes

    duplicate = validate(ArchiveGraph([geometry, geometry]))
    @test any(d -> d.code === :duplicate_object_revision, duplicate.diagnostics)
end

@testset "to_namedtuple and report cover envelope types" begin
    schema = SchemaRef(:lieb, "hubbard-sector", "1.0.0")
    obj = _obj(
        :lieb,
        "hubbard-sector",
        "sector-1",
        "rev-1";
        extras = (; sites = 8),
        references = [ArchiveReference(:parent, ObjectId("model-1"))],
    )
    nt = to_namedtuple(obj)
    @test nt.object_id == "sector-1"
    @test nt.schema.kind === Symbol("lieb/hubbard-sector")
    @test nt.references[1].name === :parent
    @test to_namedtuple(schema).version == "1.0.0"
    @test to_namedtuple(LogicalType(:integer; units = "1")).kind === :integer

    graph_nt = to_namedtuple(ArchiveGraph([obj]))
    @test graph_nt.objects[1].kind === Symbol("lieb/hubbard-sector")
    @test report(ArchiveGraph([obj])).metadata.objects == 1
end
