# Publish a semantic migration as a new AH5 archive (#140). The source
# file is not rewritten. Payload bytes stay outside the profile; content
# identity is what the successor records.

import Episteme: migrate_payload
import SHA

const ARCHIVE_MIGRATION_UUID = "22222222-2222-4222-8222-222222222222"
const ARCHIVE_MIGRATION_REV_1 = "11111111-1111-4111-8111-111111111111"
const ARCHIVE_MIGRATION_REV_2 = "22222222-2222-4222-8222-222222222222"
const ARCHIVE_MIGRATION_FIELD = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
const ARCHIVE_MIGRATION_LABEL = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"

function migrate_payload(::Val{:archive_field_v1_v2}, payload::NamedTuple, ::SchemaMigrationStep)
    return (; name = payload.name, samples = payload.values)
end

function migrate_payload(::Val{:archive_label_metadata}, payload::NamedTuple, ::SchemaMigrationStep)
    return payload
end

function _archive_migration_namespace()
    return ArchiveNamespace(
        :oodi;
        package_uuid = ARCHIVE_MIGRATION_UUID,
        display_name = "Oodi.jl",
    )
end

function _archive_migration_fields(sample_name::Symbol)
    return [
        SchemaField(
            :name,
            LogicalType(:string);
            rules = (ValidationRule(:nonempty),),
            documentation = "field name",
        ),
        SchemaField(
            sample_name,
            LogicalType(:real; units = "1");
            rank = 1,
            shape = (nothing,),
            location = "cell",
        ),
    ]
end

function _archive_migration_schema(schema_id, version, fields; migration = nothing)
    schema = SchemaRef(:oodi, schema_id, version)
    return SchemaDefinition(
        schema;
        namespace = _archive_migration_namespace(),
        compatibility = :exact_read,
        fields = fields,
        documentation = "$schema_id $version",
        package_version = "1.2.0",
        replaced_by = migration === nothing ? nothing : migration.target,
        migration = migration,
    )
end

function _archive_migration_object(schema_id, object_id, schema, content)
    return ArchiveObject(
        ObjectId(object_id),
        RevisionId(ARCHIVE_MIGRATION_REV_1);
        content_id = content,
        namespace = _archive_migration_namespace(),
        kind = schema_kind(:oodi, schema_id),
        schema = schema,
    )
end

function _archive_migration_fixture()
    values = _archive_migration_fields(:values)
    samples = _archive_migration_fields(:samples)
    field_v1_ref = SchemaRef(:oodi, "field", "1.0.0")
    field_v2_ref = SchemaRef(:oodi, "field", "2.0.0")
    label_v1_ref = SchemaRef(:oodi, "label", "1.0.0")
    label_v2_ref = SchemaRef(:oodi, "label", "1.1.0")
    field_v1 = _archive_migration_schema(
        "field", "1.0.0", values;
        migration = SchemaMigrationRef(
            field_v1_ref, field_v2_ref; implementation_id = "archive_field_v1_v2",
        ),
    )
    field_v2 = _archive_migration_schema("field", "2.0.0", samples)
    label_v1 = _archive_migration_schema(
        "label", "1.0.0", values;
        migration = SchemaMigrationRef(
            label_v1_ref, label_v2_ref; implementation_id = "archive_label_metadata",
        ),
    )
    label_v2 = _archive_migration_schema("label", "1.1.0", values)
    schemas = SchemaRegistry([field_v1, field_v2, label_v1, label_v2])
    migrations = SchemaMigrationRegistry([
        SchemaMigrationStep(
            field_v1.schema, field_v2.schema;
            implementation_id = "archive_field_v1_v2",
            required_package = "Oodi.jl",
        ),
        SchemaMigrationStep(
            label_v1.schema, label_v2.schema;
            implementation_id = "archive_label_metadata",
            rewrite_payload = false,
            required_package = "Oodi.jl",
        ),
    ])
    field_payload = (; name = "psi", values = [1.0, 2.0, 3.0])
    label_payload = (; name = "note", values = [4.0])
    field_content = canonical_content_id(field_payload)
    label_content = canonical_content_id(label_payload)
    field = _archive_migration_object("field", ARCHIVE_MIGRATION_FIELD, field_v1.schema, field_content)
    label = _archive_migration_object("label", ARCHIVE_MIGRATION_LABEL, label_v1.schema, label_content)
    revision = RevisionId(ARCHIVE_MIGRATION_REV_1)
    graph = ArchiveGraph(
        [field, label];
        heads = [WorkflowHead(WorkflowHeadId("head-main"), :main, revision)],
        revisions = [RevisionRecord(revision)],
    )
    requests = [
        MigrationRequest(field.object_id, field.revision_id, field_v2.schema, field_payload),
        MigrationRequest(label.object_id, label.revision_id, label_v2.schema, label_payload),
    ]
    software = SoftwareEnvironment([
        SoftwareComponent(
            "toy-migrator", "ToyMigrator";
            version = "1.0.0",
            source_identity = "archive-migration-fixture",
        ),
    ])
    return (;
        schemas, migrations, graph, requests, software,
        field, label, field_payload, label_payload, field_content, label_content,
        historical = SchemaRegistry([field_v1, label_v1]),
    )
end

function _archive_migration_receipt(events, object_id)
    matches = EventRecord[
        event for event in events if
            event.kind === :schema_migration && event.payload.object_id == object_id
    ]
    return only(matches)
end

@testset "historical v1 archive migrates into a new AH5 file" begin
    mktempdir() do dir
        fixture = _archive_migration_fixture()
        source_objects = copy(fixture.graph.objects)
        source_revisions = copy(fixture.graph.revisions)
        source_heads = copy(fixture.graph.heads)
        revision_id = RevisionId(ARCHIVE_MIGRATION_REV_2)
        run_id = RunId("run-schema-migration")
        prepared = migrate_archive(
            fixture.graph,
            fixture.requests,
            fixture.migrations;
            schemas = fixture.schemas,
            revision_id = revision_id,
            run_id = run_id,
            software_environment = fixture.software,
        )
        @test fixture.graph.objects == source_objects
        @test fixture.graph.revisions == source_revisions
        @test fixture.graph.heads == source_heads
        @test isvalid(prepared)
        @test !prepared.published
        @test prepared.graph !== nothing
        rewritten = find_object(prepared.graph, fixture.field.object_id, revision_id)
        reused = find_object(prepared.graph, fixture.label.object_id, revision_id)
        migrated_field = (; name = "psi", samples = [1.0, 2.0, 3.0])
        @test rewritten.content_id == canonical_content_id(migrated_field)
        @test rewritten.content_id != fixture.field_content
        @test rewritten.schema == SchemaRef(:oodi, "field", "2.0.0")
        @test reused.content_id == fixture.label_content
        @test reused.schema == SchemaRef(:oodi, "label", "1.1.0")
        @test find_object(
            prepared.graph, fixture.field.object_id, fixture.field.revision_id,
        ) == fixture.field
        parents = revision_parents(prepared.graph, revision_id)
        @test only(parents).id == fixture.field.revision_id
        @test only(prepared.graph.heads).revision_id == revision_id
        @test only(prepared.graph.runs).software_environment == fixture.software.id

        source = joinpath(dir, "historical.ah5")
        destination = joinpath(dir, "migrated.ah5")
        write_state_archive(source, fixture.graph; schemas = fixture.historical)
        before = read(source)
        digest = SHA.sha256(before)
        published = materialize_migration(
            destination,
            source,
            fixture.requests,
            fixture.migrations;
            schemas = fixture.schemas,
            revision_id = revision_id,
            run_id = run_id,
            software_environment = fixture.software,
        )
        @test isvalid(published)
        @test published.published
        @test read(source) == before
        @test SHA.sha256(read(source)) == digest
        @test isfile(destination)

        source_view = inspect_archive(source, ArchiveStateHistory)
        @test isvalid(source_view)
        @test length(source_view.state.objects) == 2
        @test all(object.revision_id == fixture.field.revision_id for object in source_view.state.objects)
        source_core = inspect_archive(source)
        @test inspect_archive(destination).profile.archive_id != source_core.profile.archive_id

        view = inspect_archive(destination, ArchiveEventHistory)
        @test isvalid(view)
        @test isvalid(validate(view))
        reopened = reconstruct_graph(view)
        @test isvalid(validate(reopened, fixture.schemas))
        @test only(revision_parents(reopened, revision_id)).id == only(parents).id
        opened_field = find_object(reopened, fixture.field.object_id, revision_id)
        opened_label = find_object(reopened, fixture.label.object_id, revision_id)
        @test opened_field.schema == rewritten.schema
        @test opened_field.content_id == rewritten.content_id
        @test find_object(reopened, fixture.field.object_id, fixture.field.revision_id).schema ==
            fixture.field.schema
        @test opened_label.schema == reused.schema
        @test opened_label.content_id == fixture.label_content
        @test opened_label.content_id == find_object(
            reopened, fixture.label.object_id, fixture.label.revision_id,
        ).content_id

        core = inspect_archive(destination)
        field_listing = only(item for item in core.schemas if item.schema == fixture.field.schema)
        label_listing = only(item for item in core.schemas if item.schema == fixture.label.schema)
        @test field_listing.migration.implementation_id == "archive_field_v1_v2"
        @test label_listing.migration.implementation_id == "archive_label_metadata"
        @test any(item -> item.schema == SchemaRef(:oodi, "field", "2.0.0"), core.schemas)
        @test any(item -> item.schema == SchemaRef(:oodi, "label", "1.1.0"), core.schemas)

        field_event = _archive_migration_receipt(view.events, fixture.field.object_id.value)
        label_event = _archive_migration_receipt(view.events, fixture.label.object_id.value)
        @test String.(field_event.payload.implementation_ids) == ["archive_field_v1_v2"]
        @test field_event.payload.rewrite_payload
        @test field_event.payload.source_version == "1.0.0"
        @test field_event.payload.target_version == "2.0.0"
        @test field_event.payload.content_id == rewritten.content_id.value
        @test String.(label_event.payload.implementation_ids) == ["archive_label_metadata"]
        @test !label_event.payload.rewrite_payload
        @test label_event.payload.content_id == fixture.label_content.value
        @test label_event.payload.source_content_id == fixture.label_content.value
        @test field_event.payload.software_environment == fixture.software.id.value
        @test only(view.runs).software_environment == fixture.software.id
        recorded = inspect_archive(destination, SoftwareEnvironmentRegistry)
        @test recorded.feature_declared
        @test find_software_environment(recorded.registry, fixture.software.id) !== nothing
    end
end

@testset "invalid migration does not publish an archive" begin
    mktempdir() do dir
        fixture = _archive_migration_fixture()
        source = joinpath(dir, "historical.ah5")
        destination = joinpath(dir, "not-published.ah5")
        write_state_archive(source, fixture.graph; schemas = fixture.historical)
        before = read(source)
        missing = SchemaMigrationRegistry([
            SchemaMigrationStep(
                fixture.field.schema,
                SchemaRef(:oodi, "field", "2.0.0");
                implementation_id = "not_loaded",
                required_package = "Oodi.jl",
            ),
        ])
        request = MigrationRequest[
            fixture.requests[1],
        ]
        unpublished = materialize_migration(
            destination,
            source,
            request,
            missing;
            schemas = fixture.schemas,
            revision_id = RevisionId(ARCHIVE_MIGRATION_REV_2),
            run_id = RunId("run-missing"),
            software_environment = fixture.software,
        )
        @test !isvalid(unpublished)
        @test !unpublished.published
        @test unpublished.graph === nothing
        @test any(diagnostic -> diagnostic.code === :migration_implementation_missing, unpublished.diagnostics)
        @test !ispath(destination)
        @test read(source) == before
        @test SHA.sha256(read(source)) == SHA.sha256(before)

        ambiguous = SchemaMigrationRegistry([
            SchemaMigrationStep(
                SchemaRef(:oodi, "field", "1.0.0"),
                SchemaRef(:oodi, "field", "2.0.0");
                implementation_id = "archive_field_v1_v2",
            ),
            SchemaMigrationStep(
                SchemaRef(:oodi, "field", "1.0.0"),
                SchemaRef(:oodi, "field", "1.5.0");
                implementation_id = "archive_field_v1_v2",
            ),
            SchemaMigrationStep(
                SchemaRef(:oodi, "field", "2.0.0"),
                SchemaRef(:oodi, "field", "3.0.0");
                implementation_id = "archive_field_v1_v2",
            ),
            SchemaMigrationStep(
                SchemaRef(:oodi, "field", "1.5.0"),
                SchemaRef(:oodi, "field", "3.0.0");
                implementation_id = "archive_label_metadata",
                rewrite_payload = false,
            ),
        ])
        versions = SchemaDefinition[]
        for version in ("1.0.0", "1.5.0", "2.0.0", "3.0.0")
            fields = version == "1.0.0" || version == "1.5.0" ?
                _archive_migration_fields(:values) :
                _archive_migration_fields(:samples)
            push!(versions, _archive_migration_schema("field", version, fields))
        end
        blocked = materialize_migration(
            destination,
            source,
            [MigrationRequest(
                fixture.field.object_id,
                fixture.field.revision_id,
                SchemaRef(:oodi, "field", "3.0.0"),
                fixture.field_payload,
            )],
            ambiguous;
            schemas = SchemaRegistry(versions),
            revision_id = RevisionId(ARCHIVE_MIGRATION_REV_2),
            run_id = RunId("run-ambiguous"),
        )
        @test !isvalid(blocked)
        @test blocked.graph === nothing
        @test any(diagnostic -> diagnostic.code === :ambiguous_migration, blocked.diagnostics)
        @test !ispath(destination)
        @test read(source) == before

        occupied = joinpath(dir, "occupied.ah5")
        write(occupied, "leave-this-file")
        @test_throws ArgumentError materialize_migration(
            occupied,
            source,
            fixture.requests,
            fixture.migrations;
            schemas = fixture.schemas,
            revision_id = RevisionId(ARCHIVE_MIGRATION_REV_2),
            run_id = RunId("run-occupied"),
            software_environment = fixture.software,
        )
        @test String(read(occupied)) == "leave-this-file"
        @test read(source) == before

        bare = joinpath(dir, "bare.ah5")
        bare_destination = joinpath(dir, "bare-out.ah5")
        write_archive(bare)
        bare_result = materialize_migration(
            bare_destination,
            bare,
            fixture.requests,
            fixture.migrations;
            schemas = fixture.schemas,
            revision_id = RevisionId(ARCHIVE_MIGRATION_REV_2),
            run_id = RunId("run-bare"),
        )
        @test !isvalid(bare_result)
        @test any(diagnostic -> diagnostic.code === :missing_state_history, bare_result.diagnostics)
        @test !ispath(bare_destination)
    end
end
