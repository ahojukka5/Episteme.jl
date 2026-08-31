const EXTERNAL_PREFLIGHT_CONTENT = "sha256:" * repeat("9", 64)
const EXTERNAL_PREFLIGHT_REMOTE = "sha256:" * repeat("8", 64)

function _external_preflight_fixture(; include_unrelated = false, bad_kind = false)
    revision = RevisionId("ext-preflight-r1")
    external_id = ObjectId("ext-preflight-geometry")
    refs = ArchiveReference[
        ArchiveReference(:geometry, external_id),
    ]
    if include_unrelated
        push!(refs, ArchiveReference(:missing, ObjectId("undeclared-missing-object")))
    end
    object = ArchiveObject(
        ObjectId("ext-preflight-mesh"),
        revision;
        content_id = ContentId(EXTERNAL_PREFLIGHT_CONTENT),
        namespace = ArchiveNamespace(
            :delone;
            package_uuid = UUID_DELONE,
            display_name = "Delone.jl",
        ),
        kind = bad_kind ? Symbol("delone/not-mesh") : Symbol("delone/mesh"),
        schema = SchemaRef(:delone, "mesh", "1.0.0"),
        references = refs,
    )
    graph = ArchiveGraph([object]; revisions = [RevisionRecord(revision)])
    external = ExternalRequirement(
        external_id;
        content_id = ContentId(EXTERNAL_PREFLIGHT_REMOTE),
        artifact = ArtifactRef(:file; path = "geometry.bin", description = "external geometry"),
    )
    return graph, revision, external_id, external
end

@testset "AH5 core preflight honors declared external object references" begin
    mktempdir() do dir
        graph, revision, external_id, external = _external_preflight_fixture()
        schemas = SchemaRegistry([_mesh_def()])
        original_refs = copy(graph.objects[1].references)

        path = joinpath(dir, "core-external.ah5")
        write_archive(
            path;
            graph = graph,
            schemas = schemas,
            externals = [external],
        )
        core = inspect_archive(path)
        @test core.identified
        @test length(core.externals) == 1
        @test only(core.externals).object_id == external_id
        @test graph.objects[1].references == original_refs

        state_path = joinpath(dir, "state-external.ah5")
        write_state_archive(
            state_path,
            graph;
            schemas = schemas,
            externals = [external],
        )
        state = inspect_archive(state_path, ArchiveStateHistory)
        @test isvalid(state)
        manifest = inspect(state, revision)
        @test any(
            entry -> entry.object_id == external_id &&
                entry.availability === :external_required,
            manifest.entries,
        )
        @test graph.objects[1].references == original_refs
    end
end

@testset "external-aware preflight remains fail-closed" begin
    mktempdir() do dir
        graph, _, _, external = _external_preflight_fixture()
        schemas = SchemaRegistry([_mesh_def()])

        missing_path = joinpath(dir, "missing-declaration.ah5")
        @test_throws ArgumentError write_archive(
            missing_path;
            graph = graph,
            schemas = schemas,
        )
        @test !ispath(missing_path)

        unrelated, _, _, external2 = _external_preflight_fixture(; include_unrelated = true)
        unrelated_path = joinpath(dir, "unrelated-dangling.ah5")
        @test_throws ArgumentError write_archive(
            unrelated_path;
            graph = unrelated,
            schemas = schemas,
            externals = [external2],
        )
        @test !ispath(unrelated_path)

        bad, _, _, external3 = _external_preflight_fixture(; bad_kind = true)
        bad_path = joinpath(dir, "bad-schema-kind.ah5")
        @test_throws ArgumentError write_archive(
            bad_path;
            graph = bad,
            schemas = schemas,
            externals = [external3],
        )
        @test !ispath(bad_path)
    end
end
