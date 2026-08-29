@testset "AH5 integrity manifests bind to the written archive" begin
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
        manifest = integrity_manifest(graph, r1, schemas)
        @test isvalid(manifest)

        empty_path = joinpath(dir, "empty.ah5")
        @test_throws ArgumentError write_archive(
            empty_path,
            RevisionIntegrityManifest[];
            graph = graph,
            schemas = schemas,
        )
        @test !ispath(empty_path)

        wrong_graph = ArchiveGraph([
            _obj(
                :delone,
                "mesh",
                ID_MESH,
                REV_1;
                content = AH5_TEST_CONTENT_B,
                uuid = UUID_DELONE,
            ),
        ]; revisions = [RevisionRecord(r1)])
        wrong_graph_path = joinpath(dir, "wrong-graph.ah5")
        @test_throws ArgumentError write_archive(
            wrong_graph_path,
            manifest;
            graph = wrong_graph,
            schemas = schemas,
        )
        @test !ispath(wrong_graph_path)

        original = _mesh_def()
        changed_schema = SchemaDefinition(
            original.schema;
            namespace = original.namespace,
            compatibility = original.compatibility,
            fields = original.fields,
            node_schema = original.node_schema,
            documentation = "changed after integrity capture",
            package_version = original.package_version,
            replaces = original.replaces,
            replaced_by = original.replaced_by,
            migration = original.migration,
        )
        wrong_schema_path = joinpath(dir, "wrong-schema.ah5")
        @test_throws ArgumentError write_archive(
            wrong_schema_path,
            manifest;
            graph = graph,
            schemas = SchemaRegistry([changed_schema]),
        )
        @test !ispath(wrong_schema_path)
    end
end

@testset "external trust rows bind to the archived ExternalRequirement" begin
    mktempdir() do dir
        path_a = joinpath(dir, "geometry-a.bin")
        path_b = joinpath(dir, "geometry-b.bin")
        bytes = repeat(UInt8[0x01, 0x02, 0x03, 0x04], 1024)
        write(path_a, bytes)
        write(path_b, bytes)

        initial = ExternalRequirement(
            ObjectId(ID_GEOM);
            artifact = ArtifactRef(:file; path = path_a, description = "geometry"),
        )
        record = capture_external_integrity(initial; sample_bytes = 64, sample_count = 3)
        requirement_a = ExternalRequirement(
            ObjectId(ID_GEOM);
            content_id = record.content_id,
            artifact = initial.artifact,
        )
        requirement_b = ExternalRequirement(
            ObjectId(ID_GEOM);
            content_id = record.content_id,
            artifact = ArtifactRef(:file; path = path_b, description = "geometry"),
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
        manifest = integrity_manifest(
            graph,
            r1,
            schemas;
            externals = [requirement_a],
            external_integrity = [record],
            level = :metadata,
        )
        @test isvalid(manifest)

        wrong_external_path = joinpath(dir, "wrong-external.ah5")
        @test_throws ArgumentError write_archive(
            wrong_external_path,
            manifest;
            graph = graph,
            schemas = schemas,
            externals = [requirement_b],
        )
        @test !ispath(wrong_external_path)
    end
end
