@testset "capsule preserves retained provenance and explicit externals" begin
    mktempdir() do dir
        source, _, revision = _event_history_fixture()
        schemas = SchemaRegistry([_mesh_def()])
        plan = plan_capsule(source, revision, schemas)
        @test isvalid(plan)
        before = to_namedtuple(source)
        path = joinpath(dir, "provenance.ah5")
        result = write_capsule_archive(path, source, plan, schemas; source_archive_id = "provenance-source")
        history = inspect_archive(path, ArchiveEventHistory)
        expected = compact_archive(source, [RetentionRoot(revision)]; policy = plan.retention.policy)
        # Portable event storage normalizes NamedTuple field order and
        # dictionary representation; compare the complete logical content.
        @test canonical_bytes(to_namedtuple(reconstruct_graph(history))) ==
            canonical_bytes(to_namedtuple(expected.graph))
        @test event_timeline(history) == event_timeline(expected.graph)
        @test length(history.events) == 2
        @test length(history.writes) == 1
        @test length(history.log_streams) == 1
        @test length(only(history.runs).staged) == 1
        @test !result.manifest.payloads_embedded
        @test to_namedtuple(source) == before
    end

    mktempdir() do dir
        external_path = joinpath(dir, "external.bin")
        write(external_path, UInt8[1, 2, 3, 4])
        artifact = ArtifactRef(:file; path = external_path)
        captured = capture_external_integrity(ExternalRequirement(ObjectId(ID_GEOM); artifact = artifact))
        requirement = ExternalRequirement(ObjectId(ID_GEOM);
            content_id = captured.content_id, artifact = artifact)
        unused = ExternalRequirement(ObjectId(ID_FIELD);
            content_id = ContentId(CAPSULE_CONTENT_B), artifact = ArtifactRef(:file; path = "unused.bin"))
        revision = RevisionId(REV_1)
        mesh = _obj(:delone, "mesh", ID_MESH, REV_1;
            content = CAPSULE_CONTENT_A, uuid = UUID_DELONE,
            references = [ArchiveReference(:geometry, ObjectId(ID_GEOM); revision_id = revision)])
        source = ArchiveGraph([mesh]; revisions = [RevisionRecord(revision)])
        schemas = SchemaRegistry([_mesh_def()])
        plan = plan_capsule(source, revision, schemas;
            externals = [requirement, unused], external_integrity = [captured])
        @test isvalid(plan)
        path = joinpath(dir, "external-capsule.ah5")
        write_capsule_archive(path, source, plan, schemas;
            source_archive_id = "external-source", externals = [requirement, unused])
        core = inspect_archive(path)
        @test length(core.externals) == 1
        @test only(core.externals).content_id == captured.content_id
        @test only(core.externals).artifact.path == external_path
        rm(external_path)
        @test isvalid(inspect_archive(path, CapsuleManifest))
        @test !inspect_archive(path, CapsuleManifest).manifest.payloads_embedded

        refused = joinpath(dir, "wrong-external.ah5")
        wrong = ExternalRequirement(ObjectId(ID_GEOM);
            content_id = ContentId(CAPSULE_CONTENT_B), artifact = artifact)
        @test_throws ArgumentError write_capsule_archive(refused, source, plan, schemas;
            source_archive_id = "external-source", externals = [wrong])
        @test !ispath(refused)
    end
end
