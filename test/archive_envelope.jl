# Logical archive envelope (#26). These tests must not require HDF5.

const ID_GEOM = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
const ID_MESH = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
const ID_SPACE = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
const ID_FIELD = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
const ID_POST = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
const ID_SECTOR = "ffffffff-ffff-4fff-8fff-ffffffffffff"
const ID_MODEL = "00000000-0000-4000-8000-000000000001"
const ID_FIELD_COPY = "00000000-0000-4000-8000-000000000002"
const ID_VOL = "00000000-0000-4000-8000-000000000003"

const REV_1 = "11111111-1111-4111-8111-111111111111"
const REV_2 = "22222222-2222-4222-8222-222222222222"
const REV_3 = "33333333-3333-4333-8333-333333333333"
const REV_4 = "44444444-4444-4444-8444-444444444444"

function _ns(id::Symbol; uuid = "", display = "")
    return ArchiveNamespace(id; package_uuid = uuid, display_name = display)
end

function _obj(
    namespace::Symbol,
    schema_id::AbstractString,
    object::AbstractString,
    revision::AbstractString;
    version = "1.0.0",
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

@testset "envelope does not store package payloads" begin
    field = _obj(:oodi, "field", ID_FIELD, REV_3)
    @test !hasfield(typeof(field), :extras)
    @test !hasfield(typeof(field), :payload)
    nt = to_namedtuple(field)
    @test !haskey(nt, :extras)
    @test nt.kind === Symbol("oodi/field")
end

@testset "geometry to field graph plus sibling-domain objects" begin
    geometry = _obj(:monge, "box", ID_GEOM, REV_1)
    mesh = _obj(
        :delone,
        "mesh",
        ID_MESH,
        REV_2;
        references = [ArchiveReference(
            :geometry,
            geometry.object_id;
            revision_id = geometry.revision_id,
        )],
    )
    # One workflow revision may materialize several objects.
    space = _obj(
        :oodi,
        "space",
        ID_SPACE,
        REV_3;
        references = [ArchiveReference(:mesh, mesh.object_id; revision_id = mesh.revision_id)],
        provenance = ProvenanceRefs(;
            software_environment = SoftwareEnvironmentId("env-1"),
            execution_context = ExecutionContextId("ctx-1"),
        ),
    )
    field = _obj(
        :oodi,
        "field",
        ID_FIELD,
        REV_3;
        content = "hash-u",
        run = "run-1",
        references = [ArchiveReference(:space, space.object_id; revision_id = space.revision_id)],
    )
    posterior = _obj(:stinespring, "posterior", ID_POST, REV_4)
    sector = _obj(:lieb, "hubbard-sector", ID_SECTOR, REV_4)
    model = _obj(:chappe, "model", ID_MODEL, REV_4)

    # Same logical content may be reused without sharing object identity.
    field_copy = _obj(:oodi, "field", ID_FIELD_COPY, REV_4; content = "hash-u")
    @test field.content_id == field_copy.content_id
    @test field.object_id != field_copy.object_id
    @test space.revision_id == field.revision_id
    @test space.object_id != field.object_id

    head = WorkflowHead(WorkflowHeadId("head-main"), :main, RevisionId(REV_3))
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
    @test find_objects(graph, RevisionId(REV_3)) == [space, field]

    appended = ArchiveGraph(vcat(graph.objects, [_obj(:sorby, "volume", ID_VOL, REV_4)]))
    @test isvalid(validate(appended))
    @test find_object(appended, mesh.object_id, mesh.revision_id).references[1].target.object_id ==
        geometry.object_id

    rep = report(field)
    @test rep.subject === Symbol("oodi/field")
    @test occursin(ID_FIELD, rep.summary)
    @test sprint(show, graph) == "ArchiveGraph(objects=8, heads=1)"
end

@testset "ObjectId is archive-global and unpinned refs are logical links" begin
    first = _obj(:oodi, "field", ID_FIELD, REV_1)
    collided = _obj(:lieb, "hubbard-sector", ID_FIELD, REV_2)
    conflict = validate(ArchiveGraph([first, collided]))
    @test !isvalid(conflict)
    @test any(d -> d.code === :object_id_namespace_conflict, conflict.diagnostics)

    same_ns_other_kind = ArchiveObject(
        ObjectId(ID_FIELD),
        RevisionId(REV_2);
        namespace = _ns(:oodi),
        kind = Symbol("oodi/space"),
        schema = SchemaRef(:oodi, "space", "1.0.0"),
    )
    kind_conflict = validate(ArchiveGraph([first, same_ns_other_kind]))
    @test any(d -> d.code === :object_id_kind_conflict, kind_conflict.diagnostics)

    geometry_v1 = _obj(:monge, "box", ID_GEOM, REV_1)
    geometry_v2 = _obj(:monge, "box", ID_GEOM, REV_2)
    unpinned = _obj(
        :delone,
        "mesh",
        ID_MESH,
        REV_2;
        references = [ArchiveReference(:geometry, ObjectId(ID_GEOM))],
    )
    @test isvalid(validate(ArchiveGraph([geometry_v1, geometry_v2, unpinned])))

    pinned_v1 = _obj(
        :delone,
        "mesh",
        ID_MESH,
        REV_2;
        references = [ArchiveReference(
            :geometry,
            ObjectId(ID_GEOM);
            revision_id = RevisionId(REV_1),
        )],
    )
    @test isvalid(validate(ArchiveGraph([geometry_v1, geometry_v2, pinned_v1])))
    @test pinned_v1.references[1].target.revision_id == RevisionId(REV_1)
end

@testset "dangling and incompatible metadata fail explicitly" begin
    geometry = _obj(:monge, "box", ID_GEOM, REV_1)
    mesh = _obj(
        :delone,
        "mesh",
        ID_MESH,
        REV_2;
        references = [ArchiveReference(:geometry, ObjectId("missing-geom-id"))],
    )
    dangling = validate(ArchiveGraph([geometry, mesh]))
    @test !isvalid(dangling)
    @test any(d -> d.code === :dangling_reference, dangling.diagnostics)

    pinned_missing = _obj(
        :delone,
        "mesh",
        ID_MESH,
        REV_2;
        references = [ArchiveReference(
            :geometry,
            geometry.object_id;
            revision_id = RevisionId("rev-absent"),
        )],
    )
    pinned = validate(ArchiveGraph([geometry, pinned_missing]))
    @test !isvalid(pinned)
    @test any(d -> d.code === :dangling_reference, pinned.diagnostics)

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
    current = _obj(:oodi, "field", ID_FIELD, REV_1)
    @test isvalid(validate(current, catalog))

    missing = _obj(:oodi, "field", ID_FIELD, REV_1; version = "3.0.0")
    @test any(d -> d.code === :missing_schema, validate(missing, catalog).diagnostics)

    old = _obj(:oodi, "field", ID_FIELD, REV_1; version = "0.9.0")
    @test any(d -> d.code === :unsupported_schema, validate(old, catalog).diagnostics)

    migrate = _obj(:oodi, "field", ID_FIELD, REV_1; version = "0.8.0")
    @test any(d -> d.code === :migration_required, validate(migrate, catalog).diagnostics)

    env_obj = _obj(
        :oodi,
        "field",
        ID_FIELD,
        REV_1;
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
        ID_SECTOR,
        REV_1;
        references = [ArchiveReference(:parent, ObjectId(ID_MODEL))],
    )
    nt = to_namedtuple(obj)
    @test nt.object_id == ID_SECTOR
    @test nt.schema.kind === Symbol("lieb/hubbard-sector")
    @test nt.references[1].name === :parent
    @test nt.references[1].target.revision_id === nothing
    @test to_namedtuple(schema).version == "1.0.0"
    @test to_namedtuple(LogicalType(:integer; units = "1")).kind === :integer

    graph_nt = to_namedtuple(ArchiveGraph([obj]))
    @test graph_nt.objects[1].kind === Symbol("lieb/hubbard-sector")
    @test report(ArchiveGraph([obj])).metadata.objects == 1
end
