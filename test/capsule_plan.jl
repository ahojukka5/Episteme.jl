const CAPSULE_CONTENT_A = "sha256:" * repeat("a", 64)
const CAPSULE_CONTENT_B = "sha256:" * repeat("b", 64)

@testset "capsule planning is revision-scoped and separates valid from ready" begin
    r1 = RevisionId(REV_1)
    r2 = RevisionId(REV_2)
    selected = _obj(
        :delone,
        "mesh",
        ID_MESH,
        REV_1;
        content = CAPSULE_CONTENT_A,
        uuid = UUID_DELONE,
    )
    unrelated = _obj(
        :oodi,
        "field",
        ID_FIELD,
        REV_2;
        content = "legacy-unrelated-content",
        uuid = UUID_OODI,
    )
    graph = ArchiveGraph(
        [unrelated, selected];
        revisions = [
            RevisionRecord(r1),
            RevisionRecord(r2; parents = [RevisionId("missing-unrelated-parent")]),
        ],
    )
    objects_before = copy(graph.objects)
    revisions_before = copy(graph.revisions)
    schemas = SchemaRegistry([_mesh_def()])

    plan = plan_capsule(graph, r1, schemas; target = :replay)
    @test isvalid(plan)
    @test isvalid(validate(plan))
    @test !isready(plan)
    @test !plan.ready
    @test any(d -> d.code === :replay_run_missing, plan.readiness_report.diagnostics)
    @test !any(d -> d.code === :dangling_parent, plan.diagnostics)

    inspect_ready = readiness(plan, PipelineTarget(:inspect))
    @test isready(inspect_ready)
    @test plan.retention.retained_objects == 1
    @test plan.retention.omitted_objects == 1
    @test [row.kind for row in plan.integrity.dependencies] == [:object, :schema]
    @test isempty(plan.externals)

    nt = to_namedtuple(plan)
    @test nt.source_revision == REV_1
    @test nt.target === :replay
    @test nt.valid
    @test !nt.ready
    @test length(nt.classifications) == 2

    @test graph.objects == objects_before
    @test graph.revisions == revisions_before
    @test_throws ArgumentError plan_capsule(graph, r1, schemas; target = :bogus)
end

@testset "external dependencies stay explicit and downgrade self-contained replay" begin
    mktempdir() do dir
        path = joinpath(dir, "geometry.bin")
        write(path, repeat(UInt8[0x01, 0x03, 0x05, 0x07], 2048))
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
            content = CAPSULE_CONTENT_A,
            uuid = UUID_DELONE,
            references = [ArchiveReference(:geometry, ObjectId(ID_GEOM); revision_id = r1)],
        )
        graph = ArchiveGraph([mesh]; revisions = [RevisionRecord(r1)])
        schemas = SchemaRegistry([_mesh_def()])

        plan = plan_capsule(
            graph,
            r1,
            schemas;
            target = :inspect,
            externals = [requirement],
            external_integrity = [record],
            verification = :sample,
        )
        @test isvalid(plan)
        @test isready(plan)
        @test plan.verification === :sample
        @test length(plan.externals) == 1
        @test plan.externals[1].object_id == ObjectId(ID_GEOM)
        @test plan.retention.external_objects == 1
        external_row = only(row for row in plan.integrity.dependencies if row.kind === :external)
        @test external_row.verified_level === :sample
        @test external_row.bytes_checked > 0

        replay = readiness(plan, PipelineTarget(:replay))
        @test !isready(replay)
        @test any(d -> d.code === :external_content_required, replay.diagnostics)
    end
end

@testset "capsule planning fails closed on weak retained content identities" begin
    r1 = RevisionId(REV_1)
    legacy = _obj(
        :delone,
        "mesh",
        ID_MESH,
        REV_1;
        content = "legacy-content-id",
        uuid = UUID_DELONE,
    )
    graph = ArchiveGraph([legacy]; revisions = [RevisionRecord(r1)])
    plan = plan_capsule(graph, r1, SchemaRegistry([_mesh_def()]))

    @test !isvalid(plan)
    @test !isready(plan)
    @test any(d -> d.code === :capsule_retained_content_identity_weak, plan.diagnostics)
    @test !isready(readiness(plan, PipelineTarget(:inspect)))
end

@testset "retention outside the selected integrity closure is explicit" begin
    r0 = RevisionId(REV_1)
    r1 = RevisionId(REV_2)
    ancestor_extra = _obj(
        :delone,
        "mesh",
        ID_GEOM,
        REV_1;
        content = CAPSULE_CONTENT_B,
        uuid = UUID_DELONE,
    )
    selected = _obj(
        :delone,
        "mesh",
        ID_MESH,
        REV_2;
        content = CAPSULE_CONTENT_A,
        uuid = UUID_DELONE,
    )
    graph = ArchiveGraph(
        [ancestor_extra, selected];
        revisions = [
            RevisionRecord(r0),
            RevisionRecord(r1; parents = [r0]),
        ],
    )
    plan = plan_capsule(
        graph,
        r1,
        SchemaRegistry([_mesh_def()]);
        policy = RetentionPolicy(; keep_ancestor_objects = true),
    )

    @test !isvalid(plan)
    @test plan.retention.retained_objects == 2
    @test any(
        d -> d.code === :capsule_retained_object_not_integrity_covered &&
            d.context.object_id == ID_GEOM,
        plan.diagnostics,
    )
end
