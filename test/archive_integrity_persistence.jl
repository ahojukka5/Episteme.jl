const AH5_TEST_CONTENT_A = "sha256:" * repeat("1", 64)
const AH5_TEST_CONTENT_B = "sha256:" * repeat("2", 64)

@testset "AH5 persists clean revision integrity manifests as an optional feature" begin
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

        path = joinpath(dir, "integrity.ah5")
        write_archive(path, manifest; graph = graph, schemas = schemas)

        core = inspect_archive(path)
        @test core.identified
        @test isvalid(validate(core))
        @test AH5_INTEGRITY_FEATURE in core.profile.features

        view = inspect_archive(path, RevisionIntegrityManifest)
        @test view.identified
        @test view.feature_declared
        @test isvalid(view)
        @test isvalid(validate(view))
        @test length(view.manifests) == 1
        restored = only(view.manifests)
        @test restored.revision_id == r1
        @test restored.requested_level === :metadata
        @test to_namedtuple(restored).dependencies == to_namedtuple(manifest).dependencies

        stored_count = JLD2.jldopen(path, "r"; plain = true) do file
            file["$(AH5_INTEGRITY_KEY)/count"]
        end
        @test stored_count == 1
    end
end

@testset "old AH5 archives remain valid without the optional integrity feature" begin
    mktempdir() do dir
        path = joinpath(dir, "old-style.ah5")
        write_archive(path; schemas = SchemaRegistry([_mesh_def()]))
        core = inspect_archive(path)
        @test core.identified
        @test AH5_INTEGRITY_FEATURE ∉ core.profile.features

        view = inspect_archive(path, RevisionIntegrityManifest)
        @test view.identified
        @test !view.feature_declared
        @test isvalid(view)
        @test isempty(view.manifests)
        @test isempty(view.diagnostics)
    end
end

@testset "invalid or ambiguous integrity persistence fails before publication" begin
    mktempdir() do dir
        r1 = RevisionId(REV_1)
        missing = _obj(:delone, "mesh", ID_MESH, REV_1; uuid = UUID_DELONE)
        graph = ArchiveGraph([missing]; revisions = [RevisionRecord(r1)])
        schemas = SchemaRegistry([_mesh_def()])
        invalid = integrity_manifest(graph, r1, schemas)
        @test !isvalid(invalid)

        invalid_path = joinpath(dir, "invalid.ah5")
        @test_throws ArgumentError write_archive(
            invalid_path,
            invalid;
            graph = graph,
            schemas = schemas,
        )
        @test !ispath(invalid_path)

        clean_obj = _obj(
            :delone,
            "mesh",
            ID_MESH,
            REV_1;
            content = AH5_TEST_CONTENT_A,
            uuid = UUID_DELONE,
        )
        clean_graph = ArchiveGraph([clean_obj]; revisions = [RevisionRecord(r1)])
        clean = integrity_manifest(clean_graph, r1, schemas)
        duplicate_path = joinpath(dir, "duplicate.ah5")
        @test_throws ArgumentError write_archive(
            duplicate_path,
            [clean, clean];
            graph = clean_graph,
            schemas = schemas,
        )
        @test !ispath(duplicate_path)

        # A caller cannot forge a persistent trust record merely by setting
        # `valid=true`; semantic row invariants are rechecked before writing.
        forged_row = IntegrityDependencyRow(
            :object,
            ObjectId(ID_MESH),
            r1,
            SchemaRef(:delone, "mesh", "1.0.0"),
            nothing,
            :envelope_only,
            nothing,
            :none,
            0,
            DiagnosticMessage[],
        )
        forged = RevisionIntegrityManifest(
            r1,
            :metadata,
            true,
            [forged_row],
            DiagnosticMessage[],
        )
        forged_path = joinpath(dir, "forged.ah5")
        @test_throws ArgumentError write_archive(
            forged_path,
            forged;
            graph = clean_graph,
            schemas = schemas,
        )
        @test !ispath(forged_path)

        # An opaque/non-cryptographic ContentId is not a persistent trust anchor.
        weak_row = IntegrityDependencyRow(
            :object,
            ObjectId(ID_MESH),
            r1,
            SchemaRef(:delone, "mesh", "1.0.0"),
            ContentId("not-a-strong-hash"),
            :envelope_only,
            nothing,
            :none,
            0,
            DiagnosticMessage[],
        )
        weak = RevisionIntegrityManifest(
            r1,
            :metadata,
            true,
            [weak_row],
            DiagnosticMessage[],
        )
        weak_path = joinpath(dir, "weak-content-id.ah5")
        @test_throws ArgumentError write_archive(
            weak_path,
            weak;
            graph = clean_graph,
            schemas = schemas,
        )
        @test !ispath(weak_path)

        collision_path = joinpath(dir, "collision.ah5")
        roots = ArchiveProfileRoots(; schemas = AH5_INTEGRITY_KEY)
        @test_throws ArgumentError write_archive(
            collision_path,
            clean;
            graph = clean_graph,
            schemas = schemas,
            profile = ArchiveProfile(; roots = roots),
        )
        @test !ispath(collision_path)
    end
end

@testset "declared integrity feature without its root is reported corrupt" begin
    mktempdir() do dir
        path = joinpath(dir, "declared-only.ah5")
        write_archive(
            path;
            profile = ArchiveProfile(; features = (AH5_INTEGRITY_FEATURE,)),
        )
        core = inspect_archive(path)
        @test core.identified
        @test isvalid(validate(core))
        @test AH5_INTEGRITY_FEATURE in core.profile.features

        view = inspect_archive(path, RevisionIntegrityManifest)
        @test view.identified
        @test view.feature_declared
        @test !isvalid(view)
        @test isempty(view.manifests)
        @test any(d -> d.code === :corrupt_integrity_manifest, view.diagnostics)
    end
end

@testset "forensic restore revalidates persisted trust semantics" begin
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

        path = joinpath(dir, "crafted.ah5")
        write_archive(
            path;
            graph = graph,
            schemas = schemas,
            profile = ArchiveProfile(; features = (AH5_INTEGRITY_FEATURE,)),
        )
        raw = Episteme._integrity_manifest_storage(manifest)
        object_index = findfirst(==("object"), raw.dep_kind)
        @test object_index !== nothing
        forged_content = copy(raw.dep_content_id)
        forged_content[object_index] = ""
        forged = merge(raw, (; dep_content_id = forged_content))
        JLD2.jldopen(path, "r+") do file
            file["$(AH5_INTEGRITY_KEY)/count"] = 1
            file["$(AH5_INTEGRITY_KEY)/1"] = forged
        end

        view = inspect_archive(path, RevisionIntegrityManifest)
        @test view.identified
        @test view.feature_declared
        @test !isvalid(view)
        @test isempty(view.manifests)
        @test any(d -> d.code === :corrupt_integrity_manifest, view.diagnostics)
    end
end

@testset "integrity feature remains optional in AH5 v1" begin
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
        path = joinpath(dir, "required.ah5")
        @test_throws ArgumentError write_archive(
            path,
            manifest;
            graph = graph,
            schemas = schemas,
            profile = ArchiveProfile(;
                features = (AH5_INTEGRITY_FEATURE,),
                required_features = (AH5_INTEGRITY_FEATURE,),
            ),
        )
        @test !ispath(path)
    end
end
