@testset "purge preserves retained scientific content identities" begin
    r1 = RevisionId(REV_1)
    r2 = RevisionId(REV_2)
    kept = _obj(:delone, "mesh", ID_MESH, REV_1; content = "hash-keep", uuid = UUID_DELONE)
    dropped = _obj(:delone, "mesh", ID_FIELD, REV_2; content = "hash-drop", uuid = UUID_DELONE)
    graph = ArchiveGraph(
        [kept, dropped];
        revisions = [RevisionRecord(r1), RevisionRecord(r2)],
    )
    schemas = SchemaRegistry([_mesh_def()])
    expected = integrity_manifest(graph, r1, schemas)
    @test isvalid(expected)
    source_objects = copy(graph.objects)

    result = compact_archive(graph, [RetentionRoot(r1)])
    @test result.source_unchanged
    compacted = result.graph
    @test compacted !== nothing
    @test compacted !== graph
    @test graph.objects == source_objects
    @test length(compacted.objects) == 1
    @test compacted.objects[1].object_id == kept.object_id
    @test compacted.objects[1].revision_id == kept.revision_id
    @test compacted.objects[1].content_id == kept.content_id

    verified = verify_integrity(expected, compacted, schemas)
    @test isvalid(verified)
    @test isvalid(validate(verified))
    @test verified.identities_preserved
    @test verified.requested_level === :metadata
    @test all(delta -> delta.outcome === :preserved, verified.deltas)
end

@testset "logical content changes require a new identity" begin
    r1 = RevisionId(REV_1)
    original = _obj(:delone, "mesh", ID_MESH, REV_1; content = "mesh-content", uuid = UUID_DELONE)
    changed = _obj(:delone, "mesh", ID_MESH, REV_1; content = "mesh-content-v2", uuid = UUID_DELONE)
    schemas = SchemaRegistry([_mesh_def()])
    expected = integrity_manifest(
        ArchiveGraph([original]; revisions = [RevisionRecord(r1)]),
        r1,
        schemas,
    )
    @test isvalid(expected)
    @test canonical_content_id((; value = 42)) != canonical_content_id((; value = 43))

    verified = verify_integrity(
        expected,
        ArchiveGraph([changed]; revisions = [RevisionRecord(r1)]),
        schemas,
    )
    @test !isvalid(verified)
    @test !verified.identities_preserved
    object_delta = only(delta for delta in verified.deltas if delta.kind === :object)
    @test object_delta.outcome === :changed
    @test any(d -> d.code === :content_identity_changed, verified.diagnostics)
    schema_delta = only(delta for delta in verified.deltas if delta.kind === :schema)
    @test schema_delta.outcome === :preserved
end

@testset "AH5 inspect is stored evidence; verify_integrity rechecks live bytes" begin
    mktempdir() do dir
        path = joinpath(dir, "artifact.bin")
        original = repeat(collect(UInt8(0):UInt8(255)), 16)
        write(path, original)
        requirement = ExternalRequirement(
            ObjectId(ID_GEOM);
            artifact = ArtifactRef(:file; path = path, description = "geometry"),
        )
        record = capture_external_integrity(requirement; sample_bytes = 16, sample_count = 3)
        declared = ExternalRequirement(
            ObjectId(ID_GEOM);
            content_id = record.content_id,
            artifact = requirement.artifact,
        )

        r1 = RevisionId(REV_1)
        mesh = _obj(
            :delone,
            "mesh",
            ID_MESH,
            REV_1;
            content = AH5_TEST_CONTENT_A,
            uuid = UUID_DELONE,
            references = [ArchiveReference(:geometry, ObjectId(ID_GEOM); revision_id = r1)],
        )
        graph = ArchiveGraph([mesh]; revisions = [RevisionRecord(r1)])
        schemas = SchemaRegistry([_mesh_def()])
        expected = integrity_manifest(
            graph,
            r1,
            schemas;
            externals = [declared],
            external_integrity = [record],
            level = :full,
        )
        @test isvalid(expected)
        external_row = only(row for row in expected.dependencies if row.kind === :external)
        @test external_row.verified_level === :full

        archive = joinpath(dir, "integrity.ah5")
        write_archive(archive, expected; graph = graph, schemas = schemas, externals = [declared])
        stored = inspect_archive(archive, RevisionIntegrityManifest)
        @test isvalid(stored)
        @test to_namedtuple(only(stored.manifests)).dependencies ==
            to_namedtuple(expected).dependencies

        live = verify_integrity(
            archive,
            graph,
            schemas;
            externals = [declared],
            external_integrity = [record],
        )
        @test isvalid(live)
        @test length(live.reports) == 1
        @test only(live.reports).identities_preserved
        @test only(live.reports).requested_level === :full
        @test only(live.reports).expected_level === :full

        mutated = copy(original)
        mutated[end] = UInt8((UInt16(mutated[end]) + 1) % 256)
        write(path, mutated)
        failed = verify_integrity(
            stored,
            graph,
            schemas;
            externals = [declared],
            external_integrity = [record],
            level = :full,
        )
        @test !isvalid(failed)
        live_report = only(failed.reports)
        @test live_report.identities_preserved
        @test live_report.requested_level === :full
        live_external = only(delta for delta in live_report.deltas if delta.kind === :external)
        @test live_external.expected_verified_level === :full
        @test live_external.observed_verified_level !== :full
        @test any(d -> d.code === :external_hash_mismatch, live_report.diagnostics)

        metadata_only = verify_integrity(
            expected,
            graph,
            schemas;
            externals = [declared],
            external_integrity = [record],
            level = :metadata,
        )
        @test metadata_only.requested_level === :metadata
        @test metadata_only.expected_level === :full
        metadata_external = only(delta for delta in metadata_only.deltas if delta.kind === :external)
        @test metadata_external.observed_verified_level === :metadata
        @test metadata_external.expected_verified_level === :full
    end
end

@testset "AH5 state-history round trip keeps envelope ContentIds" begin
    mktempdir() do dir
        r1 = RevisionId(REV_1)
        mesh = _obj(
            :delone,
            "mesh",
            ID_MESH,
            REV_1;
            content = AH5_TEST_CONTENT_A,
            uuid = UUID_DELONE,
        )
        graph = ArchiveGraph([mesh]; revisions = [RevisionRecord(r1)])
        schemas = SchemaRegistry([_mesh_def()])
        expected = integrity_manifest(graph, r1, schemas)
        path = joinpath(dir, "state.ah5")
        write_state_archive(path, graph; schemas = schemas)
        restored = inspect(inspect_archive(path, ArchiveStateHistory), r1)
        live = integrity_manifest(restored, schemas)
        verified = verify_integrity(expected, live)
        @test isvalid(verified)
        @test verified.identities_preserved
        object_delta = only(delta for delta in verified.deltas if delta.kind === :object)
        @test object_delta.expected_content_id == ContentId(AH5_TEST_CONTENT_A)
        @test object_delta.observed_content_id == ContentId(AH5_TEST_CONTENT_A)
    end
end

@testset "missing persisted integrity evidence fails closed" begin
    mktempdir() do dir
        path = joinpath(dir, "core-only.ah5")
        write_archive(path)
        r1 = RevisionId(REV_1)
        mesh = _obj(:delone, "mesh", ID_MESH, REV_1; content = AH5_TEST_CONTENT_A, uuid = UUID_DELONE)
        graph = ArchiveGraph([mesh]; revisions = [RevisionRecord(r1)])
        schemas = SchemaRegistry([_mesh_def()])
        verified = verify_integrity(path, graph, schemas)
        @test !isvalid(verified)
        @test isempty(verified.reports)
        @test any(d -> d.code === :integrity_evidence_missing, verified.diagnostics)
    end
end
