@testset "revision integrity is scoped to the selected history" begin
    r1 = RevisionId(REV_1)
    r2 = RevisionId(REV_2)
    mesh = _obj(:delone, "mesh", ID_MESH, REV_1; content = "mesh-content", uuid = UUID_DELONE)
    unrelated = _obj(:oodi, "field", ID_FIELD, REV_2; content = "field-content", uuid = UUID_OODI)
    graph = ArchiveGraph(
        [unrelated, mesh];
        revisions = [
            RevisionRecord(r1),
            RevisionRecord(r2; parents = [RevisionId("missing-unrelated-parent")]),
        ],
    )
    registry = SchemaRegistry([_mesh_def()])

    result = integrity_manifest(graph, r1, registry)
    @test isvalid(result)
    @test isvalid(validate(result))
    @test result.requested_level === :metadata
    @test !any(d -> d.code === :dangling_parent, result.diagnostics)
    @test [row.kind for row in result.dependencies] == [:object, :schema]
    object_row = only(row for row in result.dependencies if row.kind === :object)
    schema_row = only(row for row in result.dependencies if row.kind === :schema)
    @test object_row.object_id == ObjectId(ID_MESH)
    @test object_row.content_id == ContentId("mesh-content")
    @test object_row.verified_level === :none
    @test schema_row.schema == SchemaRef(:delone, "mesh", "1.0.0")
    @test startswith(schema_row.content_id.value, "sha256:")
    @test schema_row.verified_level === :none
    description = report(result)
    @test description.subject === :revision_integrity
    @test description.metadata.external_bytes_checked === Int64(0)
    @test description.metadata.dependencies == to_namedtuple(result).dependencies

    same = integrity_manifest(ArchiveGraph([mesh]; revisions = [RevisionRecord(r1)]), r1, registry)
    @test to_namedtuple(result).dependencies == to_namedtuple(same).dependencies
end

@testset "missing object identities and schemas fail closed" begin
    r1 = RevisionId(REV_1)
    no_content = _obj(:delone, "mesh", ID_MESH, REV_1; uuid = UUID_DELONE)
    graph = ArchiveGraph([no_content]; revisions = [RevisionRecord(r1)])

    missing_id = integrity_manifest(graph, r1, SchemaRegistry([_mesh_def()]))
    @test !isvalid(missing_id)
    @test any(d -> d.code === :missing_content_identity, missing_id.diagnostics)

    missing_schema = integrity_manifest(graph, r1, SchemaRegistry())
    @test !isvalid(missing_schema)
    @test any(d -> d.code === :missing_schema, missing_schema.diagnostics)
    schema_row = only(row for row in missing_schema.dependencies if row.kind === :schema)
    @test schema_row.availability === :missing
    @test schema_row.content_id === nothing

    duplicate_schema = integrity_manifest(
        graph,
        r1,
        SchemaRegistry([_mesh_def(; package_version = "1.0.0"), _mesh_def(; package_version = "2.0.0")]),
    )
    @test !isvalid(duplicate_schema)
    @test any(d -> d.code === :duplicate_schema_identity, duplicate_schema.diagnostics)
    duplicate_row = only(row for row in duplicate_schema.dependencies if row.kind === :schema)
    @test duplicate_row.availability === :ambiguous
    @test duplicate_row.content_id === nothing
end

@testset "schema canonical identity changes when logical schema content changes" begin
    r1 = RevisionId(REV_1)
    mesh = _obj(:delone, "mesh", ID_MESH, REV_1; content = "mesh-content", uuid = UUID_DELONE)
    graph = ArchiveGraph([mesh]; revisions = [RevisionRecord(r1)])
    original = _mesh_def()
    changed = SchemaDefinition(
        original.schema;
        namespace = original.namespace,
        compatibility = original.compatibility,
        fields = original.fields,
        node_schema = original.node_schema,
        documentation = "tampered schema documentation",
        package_version = original.package_version,
        replaces = original.replaces,
        replaced_by = original.replaced_by,
        migration = original.migration,
    )
    before = integrity_manifest(graph, r1, SchemaRegistry([original]))
    after = integrity_manifest(graph, r1, SchemaRegistry([changed]))
    before_hash = only(row.content_id for row in before.dependencies if row.kind === :schema)
    after_hash = only(row.content_id for row in after.dependencies if row.kind === :schema)
    @test before_hash != after_hash
end

@testset "external integrity rows expose requested and achieved strength" begin
    mktempdir() do dir
        path = joinpath(dir, "geometry.bin")
        write(path, repeat(UInt8[0x10, 0x20, 0x30, 0x40], 4096))

        initial = ExternalRequirement(
            ObjectId(ID_GEOM);
            artifact = ArtifactRef(:file; path = path, description = "external geometry"),
        )
        record = capture_external_integrity(initial; sample_bytes = 128, sample_count = 3)
        requirement = ExternalRequirement(
            ObjectId(ID_GEOM);
            content_id = record.content_id,
            artifact = initial.artifact,
        )
        r1 = RevisionId(REV_1)
        mesh = _obj(
            :delone,
            "mesh",
            ID_MESH,
            REV_1;
            content = "mesh-content",
            uuid = UUID_DELONE,
            references = [
                ArchiveReference(:geometry, ObjectId(ID_GEOM); revision_id = r1),
            ],
        )
        graph = ArchiveGraph([mesh]; revisions = [RevisionRecord(r1)])
        registry = SchemaRegistry([_mesh_def()])

        sampled = integrity_manifest(
            graph,
            r1,
            registry;
            externals = [requirement],
            external_integrity = [record],
            level = :sample,
        )
        @test isvalid(sampled)
        external = only(row for row in sampled.dependencies if row.kind === :external)
        @test sampled.requested_level === :sample
        @test external.content_id == record.content_id
        @test external.verified_level === :sample
        @test external.bytes_checked > 0
        @test external.bytes_checked < record.size
        @test report(sampled).metadata.external_bytes_checked == external.bytes_checked

        no_record = integrity_manifest(
            graph,
            r1,
            registry;
            externals = [requirement],
            level = :metadata,
        )
        @test !isvalid(no_record)
        @test any(d -> d.code === :external_integrity_record_missing, no_record.diagnostics)

        rm(path)
        missing = integrity_manifest(
            graph,
            r1,
            registry;
            externals = [requirement],
            external_integrity = [record],
            level = :full,
        )
        @test !isvalid(missing)
        @test any(d -> d.code === :external_artifact_missing, missing.diagnostics)
        missing_external = only(row for row in missing.dependencies if row.kind === :external)
        @test missing_external.verified_level === :none
    end
end

@testset "external integrity records are matched from one index" begin
    mktempdir() do dir
        path_a = joinpath(dir, "a.bin")
        path_b = joinpath(dir, "b.bin")
        write(path_a, UInt8[1, 2, 3, 4])
        write(path_b, UInt8[5, 6, 7, 8])
        artifact_a = ArtifactRef(:file; path = path_a, description = "a")
        artifact_b = ArtifactRef(:file; path = path_b, description = "b")
        record_a = capture_external_integrity(
            ExternalRequirement(ObjectId("obj-a"); artifact = artifact_a);
            sample_bytes = 1,
            sample_count = 1,
        )
        record_a_again = capture_external_integrity(
            ExternalRequirement(ObjectId("obj-a"); artifact = artifact_a);
            sample_bytes = 1,
            sample_count = 1,
        )
        record_b = capture_external_integrity(
            ExternalRequirement(ObjectId("obj-b"); artifact = artifact_b);
            sample_bytes = 1,
            sample_count = 1,
        )
        index = Episteme._external_integrity_index([record_a, record_a_again, record_b])
        hit, status = Episteme._match_external_integrity(
            index, record_b.object_id, record_b.content_id,
        )
        @test status === :exact
        @test hit.content_id == record_b.content_id
        _, ambiguous = Episteme._match_external_integrity(
            index, record_a.object_id, record_a.content_id,
        )
        @test ambiguous === :ambiguous
        missing, missing_status = Episteme._match_external_integrity(
            index, ObjectId("missing"), nothing,
        )
        @test missing === nothing
        @test missing_status === :missing
        only_index = Episteme._external_integrity_index([record_b])
        only_hit, only_status = Episteme._match_external_integrity(
            only_index, record_b.object_id, nothing,
        )
        @test only_status === :object_only
        @test only_hit === record_b
        _, fallback = Episteme._match_external_integrity(
            only_index, record_b.object_id, ContentId("other-content"),
        )
        @test fallback === :object_only
        @test length(index) == 2
        @test length(index[record_a.object_id]) == 2
        @test length(only_index) == 1
    end
end

@testset "empty revision integrity reports zero external bytes" begin
    manifest = RevisionIntegrityManifest(
        RevisionId("empty-revision"), :metadata, true,
        IntegrityDependencyRow[], DiagnosticMessage[],
    )
    description = report(manifest)
    @test description.metadata.external_bytes_checked === Int64(0)
    @test description.metadata.dependencies == ()
    @test isempty(description.artifacts)
    @test isempty(description.diagnostics)
end
