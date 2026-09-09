@testset "capsule materialization revalidates its source before I/O" begin
    r1 = RevisionId(REV_1)
    mesh = _obj(:delone, "mesh", ID_MESH, REV_1;
        content = CAPSULE_CONTENT_A, uuid = UUID_DELONE)
    source = ArchiveGraph([mesh]; revisions = [RevisionRecord(r1)])
    schemas = SchemaRegistry([_mesh_def()])
    before = to_namedtuple(source)

    # Inspectable metadata is useful even when the requested replay is not ready.
    plan = plan_capsule(source, r1, schemas; target = :replay)
    @test isvalid(plan)
    @test !isready(plan)
    result = Episteme._compact_capsule_source(source, plan, schemas)
    @test result.source_unchanged
    @test result.graph !== source
    @test to_namedtuple(result.graph) == before
    @test to_namedtuple(source) == before

    changed = ArchiveGraph([
        _obj(:delone, "mesh", ID_MESH, REV_1;
            content = CAPSULE_CONTENT_B, uuid = UUID_DELONE),
    ]; revisions = source.revisions)
    @test_throws ArgumentError Episteme._compact_capsule_source(changed, plan, schemas)
    # Package release provenance is deliberately outside semantic schema identity.
    @test Episteme._compact_capsule_source(
        source, plan, SchemaRegistry([_mesh_def(package_version = "0.5.0")]),
    ).graph !== nothing
    changed_schemas = deepcopy(schemas)
    pop!(changed_schemas.entries[1].fields)
    @test_throws ArgumentError Episteme._compact_capsule_source(source, plan, changed_schemas)

    # An unrelated new branch changes the omitted set, even when the selected
    # revision and its content identities are unchanged.
    expanded = ArchiveGraph([
        mesh,
        _obj(:delone, "mesh", ID_FIELD, REV_2;
            content = CAPSULE_CONTENT_B, uuid = UUID_DELONE),
    ]; revisions = [RevisionRecord(r1), RevisionRecord(RevisionId(REV_2))])
    @test_throws ArgumentError Episteme._compact_capsule_source(expanded, plan, schemas)

    changed_retention = deepcopy(plan)
    empty!(changed_retention.retention.retained_revisions)
    @test isvalid(changed_retention) # The stale cached flag must not be trusted.
    @test_throws ArgumentError Episteme._compact_capsule_source(source, changed_retention, schemas)

    changed_runs = deepcopy(plan)
    push!(changed_runs.retention.retained_runs, RunId("forged-retained-run"))
    @test_throws ArgumentError Episteme._compact_capsule_source(source, changed_runs, schemas)

    changed_integrity = deepcopy(plan)
    empty!(changed_integrity.integrity.dependencies)
    @test isvalid(changed_integrity)
    @test_throws ArgumentError Episteme._compact_capsule_source(source, changed_integrity, schemas)
    @test to_namedtuple(source) == before
end

@testset "standalone metadata capsule publication and forensic inspection" begin
    r1, r2 = RevisionId(REV_1), RevisionId(REV_2)
    mesh = _obj(:delone, "mesh", ID_MESH, REV_1;
        content = CAPSULE_CONTENT_A, uuid = UUID_DELONE)
    unrelated = _obj(:delone, "mesh", ID_FIELD, REV_2;
        content = CAPSULE_CONTENT_B, uuid = UUID_DELONE, version = "2.0.0")
    source = ArchiveGraph([mesh, unrelated]; revisions = [RevisionRecord(r1), RevisionRecord(r2)])
    schemas = SchemaRegistry([_mesh_def(), _mesh_def(version = "2.0.0")])
    plan = plan_capsule(source, r1, schemas; target = :replay)
    before = to_namedtuple(source)
    mktempdir() do dir
        path = joinpath(dir, "standalone.ah5")
        result = write_capsule_archive(path, source, plan, schemas; source_archive_id = "source-archive")
        @test result isa CapsuleArchiveResult
        @test result.source_unchanged
        @test result.manifest.source_archive_id == "source-archive"
        @test result.manifest.archive_id != "source-archive"
        @test !result.manifest.payloads_embedded
        @test result.manifest.target === :replay
        @test result.manifest.counts.omitted_objects == 1
        @test to_namedtuple(source) == before
        @test readdir(dir) == ["standalone.ah5"]
        generic = inspect_archive(path)
        @test generic.identified
        @test isvalid(validate(generic))
        @test length(generic.schemas) == 1
        @test only(generic.schemas).schema == mesh.schema
        view = inspect_archive(path, CapsuleManifest)
        @test isvalid(view)
        @test isvalid(validate(view))
        @test view.feature_declared
        @test to_namedtuple(view.manifest) == to_namedtuple(result.manifest)
        restored = reconstruct_graph(inspect_archive(path, ArchiveEventHistory))
        @test [object.object_id for object in restored.objects] == [mesh.object_id]
        @test [revision.id for revision in restored.revisions] == [r1]
        @test isvalid(inspect_archive(path, RevisionIntegrityManifest))

        bytes = read(path)
        @test_throws ArgumentError write_capsule_archive(path, source, plan, schemas;
            source_archive_id = "source-archive")
        @test read(path) == bytes
        refused = joinpath(dir, "refused.ah5")
        @test_throws ArgumentError write_capsule_archive(refused, source, plan, schemas;
            source_archive_id = "source-archive", profile = ArchiveProfile(archive_id = "source-archive"))
        @test !ispath(refused)
        @test_throws ArgumentError write_capsule_archive(refused, source, plan, schemas;
            source_archive_id = "source-archive",
            profile = ArchiveProfile(roots = ArchiveProfileRoots(schemas = "episteme/capsule")))
        @test !ispath(refused)
        @test readdir(dir) == ["standalone.ah5"]

        # A layer-level failure after staging begins must leave no destination
        # or temporary directory behind.
        unsupported = ArchiveProfile(profile_version = "999.0.0")
        @test_throws ArgumentError write_capsule_archive(refused, source, plan, schemas;
            source_archive_id = "source-archive", profile = unsupported)
        @test !ispath(refused)
        @test readdir(dir) == ["standalone.ah5"]

        # The specialized forensic reader must reject a forged completeness claim.
        JLD2.jldopen(path, "r+") do file
            stored = Episteme._capsule_manifest_storage(result.manifest)
            delete!(file, Episteme.AH5_CAPSULE_KEY)
            file[Episteme.AH5_CAPSULE_KEY] = merge(stored, (payloads_embedded = true,))
        end
        @test !isvalid(inspect_archive(path, CapsuleManifest))
    end
end

@testset "capsule schemas include retained staging and exclude unused versions" begin
    mesh = _obj(:delone, "mesh", ID_MESH, REV_1;
        content = CAPSULE_CONTENT_A, uuid = UUID_DELONE)
    staged = StagedObject(ObjectId(ID_FIELD);
        namespace = _field_def().namespace, kind = Symbol("oodi/field"),
        schema = _field_def().schema, content_id = ContentId(CAPSULE_CONTENT_B))
    graph = ArchiveGraph([mesh]; runs = [RunRecord(RunId("staged-run"); staged = [staged])])
    schemas = SchemaRegistry([_mesh_def(version = "2.0.0"), _field_def(), _mesh_def()])
    filtered = Episteme._capsule_schemas(graph, schemas)
    @test Set(def.schema for def in filtered.entries) == Set([mesh.schema, staged.schema])
    @test length(schemas.entries) == 3
    @test_throws ArgumentError Episteme._capsule_schemas(graph, SchemaRegistry([_mesh_def()]))
    @test_throws ArgumentError Episteme._capsule_schemas(graph,
        SchemaRegistry([_mesh_def(), _mesh_def(), _field_def()]))
end
