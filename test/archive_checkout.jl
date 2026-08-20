# Lazy revision inspect/checkout (#33). No file I/O, no payload load.

function _branched_history()
    r0 = RevisionId(REV_1)
    r1 = RevisionId(REV_2)
    r2 = RevisionId(REV_3)
    r3 = RevisionId(REV_4)
    rec0 = RevisionRecord(r0; plan_id = PlanId("plan-1"))
    rec1 = RevisionRecord(r1; parents = [r0], run_id = RunId("run-1"), plan_id = PlanId("plan-1"))
    rec2 = RevisionRecord(r2; parents = [r0])
    rec3 = RevisionRecord(r3; parents = [r1, r2], run_id = RunId("run-merge"))
    geom = _obj(:example, "geometry", ID_GEOM, REV_1; content = "hash-g")
    state0 = _obj(:example, "model-state", ID_SECTOR, REV_1; content = "hash-x")
    state1 = _obj(
        :example, "model-state", ID_SECTOR, REV_2;
        content = "hash-x",
        run = "run-1",
        provenance = ProvenanceRefs(; software_environment = SoftwareEnvironmentId("env-1")),
        references = [ArchiveReference(:geometry, ObjectId(ID_GEOM); revision_id = RevisionId(REV_1))],
    )
    mesh = _obj(:example, "mesh", ID_MESH, REV_3; content = "hash-y")
    state3 = _obj(:example, "model-state", ID_SECTOR, REV_4; content = "hash-x")
    activity = ActivityRecord(ActivityId("act-1"), RunId("run-1"), Symbol("example/step"))
    run = RunRecord(
        RunId("run-1");
        plan_id = PlanId("plan-1"),
        revision_id = r1,
        status = :completed,
        software_environment = SoftwareEnvironmentId("env-1"),
        activities = [activity],
        restart = RestartRequirement(;
            checkpoints = [CheckpointRef(
                ObjectId(ID_SECTOR);
                content_id = ContentId("hash-x"),
                revision_id = r1,
            )],
        ),
    )
    merge_run = RunRecord(RunId("run-merge"); revision_id = r3, status = :completed)
    graph = ArchiveGraph(
        [geom, state0, state1, mesh, state3];
        heads = [
            WorkflowHead(WorkflowHeadId("head-main"), :main, r1),
            WorkflowHead(WorkflowHeadId("head-exp"), :experiment, r2),
        ],
        revisions = [rec0, rec1, rec2, rec3],
        runs = [run, merge_run],
    )
    return graph, r0, r1, r2, r3, run
end

@testset "inspect and checkout return lazy manifests for branched history" begin
    graph, r0, r1, r2, r3, run = _branched_history()
    @test isvalid(validate(graph))
    m0 = inspect(graph, r0)
    m1 = inspect(graph, r1)
    m2 = checkout(graph, r2)
    m3 = inspect(graph, r3)
    @test m0.mode === :inspect
    @test m2.mode === :checkout
    @test Set(e.object_id for e in m0.entries) == Set([ObjectId(ID_GEOM), ObjectId(ID_SECTOR)])
    @test select(m1, ObjectId(ID_SECTOR)).availability === :envelope_only
    @test select(m1, ObjectId(ID_SECTOR)).object.content_id == ContentId("hash-x")
    @test select(m1, ObjectId(ID_GEOM)).availability === :envelope_only
    @test select(m1, ObjectId(ID_GEOM)).object.revision_id == r0
    @test Set(e.object_id for e in m1.entries) == Set([ObjectId(ID_SECTOR), ObjectId(ID_GEOM)])
    @test select(m2, ObjectId(ID_MESH)).object.kind === Symbol("example/mesh")
    @test m1.parents == [r0]
    @test Set(m3.parents) == Set([r1, r2])
    @test r0 in m3.ancestors
    @test r3 in m0.descendants
    @test m1.run.id == run.id
    @test m1.plan_id == PlanId("plan-1")
    @test [h.name for h in m1.heads] == [:main]
    @test isempty(m3.heads)
    @test inspect(graph, :main).revision.id == r1
    @test inspect(graph, WorkflowHeadId("head-exp")).revision.id == r2
    @test inspect(graph, run.id).revision.id == r1
    @test isvalid(validate(m1))
    @test isready(readiness(m1, PipelineTarget(:inspect)))
    nt = to_namedtuple(m1)
    @test nt.mode === :inspect
    @test nt.run_id == "run-1"
    @test :RevisionManifest in names(Episteme)
    @test :inspect in names(Episteme)
    @test :checkout in names(Episteme)
end

@testset "checkout does not load payloads; heads are not revision identity" begin
    graph, r0, r1, _, _, _ = _branched_history()
    before = inspect(graph, r1)
    entry = select(before, ObjectId(ID_SECTOR))
    @test entry.object isa ArchiveObject
    @test !hasfield(typeof(entry), :payload)
    @test entry.availability === :envelope_only
    fork = branch_from(r1; id = WorkflowHeadId("head-fork"), name = :fork)
    @test fork.revision_id == r1
    after_graph = ArchiveGraph(
        graph.objects;
        heads = vcat(graph.heads, [fork]),
        revisions = graph.revisions,
        runs = graph.runs,
        events = graph.events,
    )
    after = inspect(after_graph, r1)
    @test after.revision == before.revision
    @test [e.object for e in after.entries if e.object !== nothing] ==
        [e.object for e in before.entries if e.object !== nothing]
    @test :fork in (h.name for h in after.heads)
    @test :fork ∉ (h.name for h in before.heads)
    @test graph.objects == after_graph.objects
    @test graph.revisions == after_graph.revisions
end

@testset "missing archive objects differ from declared external content" begin
    obj = _obj(
        :example, "mesh", ID_MESH, REV_1;
        references = [ArchiveReference(:geometry, ObjectId(ID_GEOM); revision_id = RevisionId(REV_1))],
    )
    rec = RevisionRecord(RevisionId(REV_1))
    graph = ArchiveGraph([obj]; revisions = [rec])
    missing = inspect(graph, RevisionId(REV_1))
    @test !isvalid(validate(missing))
    @test select(missing, ObjectId(ID_GEOM)).availability === :missing
    @test !isready(readiness(missing, PipelineTarget(:inspect)))
    @test any(d -> d.code === :missing_manifest_object, missing.diagnostics)

    ext = ExternalRequirement(
        ObjectId(ID_GEOM);
        content_id = ContentId("hash-g"),
        artifact = ArtifactRef(:file; path = "geometry.bin", description = "external geometry"),
    )
    present = inspect(graph, RevisionId(REV_1); externals = [ext])
    @test isvalid(validate(present))
    @test select(present, ObjectId(ID_GEOM)).availability === :external_required
    @test select(present, ObjectId(ID_GEOM)).artifact.path == "geometry.bin"
    @test isready(readiness(present, PipelineTarget(:inspect)))
    @test !isready(readiness(present, PipelineTarget(:replay)))
    @test any(d -> d.code === :external_content_required,
        readiness(present, PipelineTarget(:replay)).diagnostics)
    @test !isready(readiness(present, PipelineTarget(:rerun)))
    @test any(e -> e.availability === :external_required, present.entries)
    @test !any(e -> e.availability === :missing, present.entries)
end

@testset "replay restart and rerun readiness are explicit" begin
    graph, _, r1, r2, _, run = _branched_history()
    m1 = inspect(graph, r1)
    @test isready(readiness(m1, PipelineTarget(:replay)))
    @test isready(readiness(m1, PipelineTarget(:rerun)))
    @test isready(readiness(m1, PipelineTarget(:restart)))

    m2 = inspect(graph, r2)
    @test m2.run === nothing
    @test !isready(readiness(m2, PipelineTarget(:replay)))
    @test any(d -> d.code === :replay_run_missing, readiness(m2, PipelineTarget(:replay)).diagnostics)
    @test !isready(readiness(m2, PipelineTarget(:rerun)))
    @test !isready(readiness(m2, PipelineTarget(:restart)))
    @test any(d -> d.code === :restart_not_declared,
        readiness(m2, PipelineTarget(:restart)).diagnostics)

    bare = RunRecord(RunId("run-merge"); revision_id = RevisionId(REV_4), status = :completed)
    merge_graph = ArchiveGraph(
        graph.objects;
        heads = graph.heads,
        revisions = graph.revisions,
        runs = [run, bare],
    )
    m3 = inspect(merge_graph, RevisionId(REV_4))
    @test !isready(readiness(m3, PipelineTarget(:replay)))
    @test any(d -> d.code === :replay_environment_unknown,
        readiness(m3, PipelineTarget(:replay)).diagnostics)
    @test !isready(readiness(m3, PipelineTarget(:rerun)))
    @test any(d -> d.code === :rerun_activity_missing,
        readiness(m3, PipelineTarget(:rerun)).diagnostics)
    @test_throws ArgumentError inspect(graph, RunId("missing"))
    @test_throws ArgumentError inspect(graph, RevisionId("no-such-revision"))
end

@testset "historical manifests are revision-scoped and include resolved deps" begin
    graph, r0, r1, r2, _, _ = _branched_history()
    m1 = inspect(graph, r1)
    @test select(m1, ObjectId(ID_GEOM)).object.revision_id == r0

    root = RevisionRecord(RevisionId(REV_1))
    child = RevisionRecord(RevisionId(REV_2); parents = [RevisionId(REV_1)])
    unpinned = _obj(
        :example, "mesh", ID_MESH, REV_2;
        references = [ArchiveReference(:geometry, ObjectId(ID_GEOM))],
    )
    sibling_geom = _obj(:example, "geometry", ID_GEOM, REV_3; content = "hash-g")
    sibling = RevisionRecord(RevisionId(REV_3); parents = [RevisionId(REV_1)])
    scoped = ArchiveGraph(
        [unpinned, sibling_geom];
        revisions = [root, child, sibling],
    )
    older = inspect(scoped, RevisionId(REV_2))
    @test select(older, ObjectId(ID_GEOM)).availability === :missing
    @test !isvalid(validate(older))
    healed = inspect(scoped, RevisionId(REV_3))
    @test select(healed, ObjectId(ID_GEOM)).availability === :envelope_only
end

@testset "selected-revision dangling parents do not hide behind other branches" begin
    good = RevisionRecord(RevisionId(REV_1))
    obj = _obj(:example, "geometry", ID_GEOM, REV_1; content = "hash-g")
    dangling = RevisionRecord(RevisionId(REV_2); parents = [RevisionId("missing-parent")])
    other = _obj(:example, "mesh", ID_MESH, REV_2; content = "hash-y")
    graph = ArchiveGraph(
        [obj, other];
        revisions = [good, dangling],
    )
    ok = inspect(graph, RevisionId(REV_1))
    @test isvalid(validate(ok))
    @test isready(readiness(ok, PipelineTarget(:inspect)))
    broken = inspect(graph, RevisionId(REV_2))
    @test any(d -> d.code === :dangling_parent, broken.diagnostics)
    @test !isvalid(validate(broken))
    @test !isready(readiness(broken, PipelineTarget(:inspect)))

    ancestor = RevisionRecord(RevisionId(REV_1); parents = [RevisionId("missing-ancestor")])
    child = RevisionRecord(RevisionId(REV_2); parents = [RevisionId(REV_1)])
    child_obj = _obj(:example, "mesh", ID_MESH, REV_2; content = "hash-y")
    chained = ArchiveGraph(
        [child_obj];
        revisions = [ancestor, child],
    )
    from_child = inspect(chained, RevisionId(REV_2))
    @test any(d -> d.code === :dangling_parent && d.context.revision_id == REV_1,
        from_child.diagnostics)
    @test !isready(readiness(from_child, PipelineTarget(:inspect)))
end

@testset "select is revision-aware when one ObjectId has several versions" begin
    r1 = RevisionId(REV_1)
    r2 = RevisionId(REV_2)
    g1 = _obj(:example, "geometry", ID_GEOM, REV_1; content = "hash-g1")
    g2 = _obj(
        :example, "geometry", ID_GEOM, REV_2;
        content = "hash-g2",
        references = [ArchiveReference(:prior, ObjectId(ID_GEOM); revision_id = r1)],
    )
    graph = ArchiveGraph(
        [g1, g2];
        revisions = [
            RevisionRecord(r1),
            RevisionRecord(r2; parents = [r1]),
        ],
    )
    manifest = inspect(graph, r2)
    @test select(manifest, ObjectId(ID_GEOM), r1).content_id == ContentId("hash-g1")
    @test select(manifest, ObjectId(ID_GEOM), r2).content_id == ContentId("hash-g2")
    @test select(manifest, ObjectRef(ObjectId(ID_GEOM), r1)).availability === :envelope_only
    @test_throws ArgumentError select(manifest, ObjectId(ID_GEOM))
end

@testset "duplicate workflow head names are rejected" begin
    rec = RevisionRecord(RevisionId(REV_1))
    obj = _obj(:example, "geometry", ID_GEOM, REV_1)
    graph = ArchiveGraph(
        [obj];
        heads = [
            WorkflowHead(WorkflowHeadId("head-a"), :main, RevisionId(REV_1)),
            WorkflowHead(WorkflowHeadId("head-b"), :main, RevisionId(REV_1)),
        ],
        revisions = [rec],
    )
    @test any(d -> d.code === :duplicate_workflow_head_name, validate(graph).diagnostics)
    @test_throws ArgumentError inspect(graph, :main)
    @test inspect(graph, WorkflowHeadId("head-a")).revision.id == RevisionId(REV_1)
end
