# Explicit purge/compaction (#31). Source graph is never mutated.

function _purge_fixture()
    graph, r0, r1, r2, r3, run = _branched_history()
    failed = RunRecord(RunId("run-failed"); status = :failed)
    debug_log = LogStreamRecord(failed.id, :stderr; retention = :debug, summary = "noise")
    pinned_log = LogStreamRecord(RunId("run-1"), :stdout; retention = :pinned, summary = "keep")
    # rebuild graph with extra run/logs; merge_run already in fixture
    graph = ArchiveGraph(
        graph.objects;
        heads = graph.heads,
        revisions = graph.revisions,
        runs = vcat(graph.runs, [failed]),
        events = [
            EventRecord(:done, run.id; sequence = 1, retention = :forensic),
            EventRecord(:debug, RunId("run-merge"); sequence = 0, retention = :debug),
        ],
        log_streams = [debug_log, pinned_log],
    )
    return graph, r0, r1, r2, r3, run
end

function _graph_with(
    graph::ArchiveGraph;
    objects = graph.objects,
    heads = graph.heads,
    revisions = graph.revisions,
    runs = graph.runs,
    events = graph.events,
    writes = graph.writes,
    log_streams = graph.log_streams,
)
    return ArchiveGraph(
        objects;
        heads = heads,
        revisions = revisions,
        runs = runs,
        events = events,
        writes = writes,
        log_streams = log_streams,
    )
end

function _run_with(
    run::RunRecord;
    parent_run_id = run.parent_run_id,
    activities = run.activities,
)
    return RunRecord(
        run.id;
        plan_id = run.plan_id,
        parent_run_id = parent_run_id,
        revision_id = run.revision_id,
        status = run.status,
        software_environment = run.software_environment,
        execution_context = run.execution_context,
        agent_id = run.agent_id,
        activities = activities,
        staged = run.staged,
        restart = run.restart,
    )
end

@testset "compacted archive drops unreachable branches and keeps required deps" begin
    graph, r0, r1, r2, r3, run = _purge_fixture()
    n_objects = length(graph.objects)
    roots = [RetentionRoot(WorkflowHeadId("head-main"))]
    plan = plan_purge(graph, roots)
    @test r1 in plan.retained_revisions
    @test r0 in plan.retained_revisions
    @test r2 in plan.omitted_revisions
    @test r3 in plan.omitted_revisions
    @test plan.omitted_objects >= 1
    result = compact_archive(graph, roots)
    @test result.source_unchanged
    @test result.graph !== graph
    @test length(graph.objects) == n_objects
    compacted = result.graph
    @test compacted !== nothing
    @test isvalid(result.report)
    @test find_revision(compacted, r2) === nothing
    @test find_object(compacted, ObjectId(ID_MESH), r2) === nothing
    @test find_object(compacted, ObjectId(ID_GEOM), r0) !== nothing
    @test find_object(compacted, ObjectId(ID_SECTOR), r1) !== nothing
    @test find_object(compacted, ObjectId(ID_SECTOR), r0) === nothing
    m1 = inspect(compacted, r1)
    @test isready(readiness(m1, PipelineTarget(:inspect)))
    @test select(m1, ObjectId(ID_GEOM)).object.revision_id == r0
    @test isready(readiness(result, PipelineTarget(:inspect)))
    @test isvalid(validate(plan))
    @test report(plan).metadata.omitted_objects == plan.omitted_objects
    @test to_namedtuple(plan).retained_objects == plan.retained_objects
    @test :compact_archive in names(Episteme)
end

@testset "identical retained content is counted once; pinned logs survive" begin
    graph, _, r1, _, _, _ = _purge_fixture()
    plan = plan_purge(
        graph,
        [RetentionRoot(r1)];
        content_sizes = Dict(ContentId("hash-x") => 10, ContentId("hash-g") => 5, ContentId("hash-y") => 7),
    )
    @test plan.retained_content == 2
    @test plan.omitted_content >= 1
    @test plan.omitted_bytes == 7
    @test plan.retained_bytes == 15
    result = compact_archive(graph, [RetentionRoot(r1)])
    compacted = result.graph
    @test any(s -> s.retention === :pinned, compacted.log_streams)
    @test !any(s -> s.retention === :debug && s.run_id == RunId("run-failed"), compacted.log_streams)
    @test find_run(compacted, RunId("run-failed")) === nothing
end

@testset "externals remain requirements; failed verification does not yield a graph" begin
    mesh = _obj(
        :example, "mesh", ID_MESH, REV_1;
        references = [ArchiveReference(:geometry, ObjectId(ID_GEOM); revision_id = RevisionId(REV_1))],
    )
    graph = ArchiveGraph(
        [mesh];
        heads = [WorkflowHead(WorkflowHeadId("h"), :main, RevisionId(REV_1))],
        revisions = [RevisionRecord(RevisionId(REV_1))],
    )
    plan = plan_purge(graph, [RetentionRoot(RevisionId(REV_1))])
    @test !isvalid(validate(plan))
    @test any(d -> d.code === :missing_manifest_object, plan.diagnostics)
    @test any(d -> d.code === :missing_manifest_object, validate(plan).diagnostics)
    failed = compact_archive(graph, [RetentionRoot(RevisionId(REV_1))])
    @test failed.source_unchanged
    @test failed.graph === nothing
    @test !isvalid(failed.report)
    @test !isready(readiness(failed, PipelineTarget(:inspect)))

    ext = ExternalRequirement(
        ObjectId(ID_GEOM);
        content_id = ContentId("hash-g"),
        artifact = ArtifactRef(:file; path = "geometry.bin"),
    )
    ok = compact_archive(graph, [RetentionRoot(RevisionId(REV_1))]; externals = [ext])
    @test ok.graph !== nothing
    @test ok.plan.external_objects == 1
    @test any(c -> c.class === :external, ok.plan.classifications)
    m = inspect(ok.graph, RevisionId(REV_1); externals = [ext])
    @test isready(readiness(m, PipelineTarget(:inspect)))
    @test select(m, ObjectId(ID_GEOM)).availability === :external_required
end

@testset "keep_ancestor_objects and uncommitted-run policy are explicit" begin
    graph, r0, r1, _, _, _ = _purge_fixture()
    slim = compact_archive(graph, [RetentionRoot(r1)])
    @test find_object(slim.graph, ObjectId(ID_SECTOR), r0) === nothing
    wide = compact_archive(
        graph,
        [RetentionRoot(r1)];
        policy = RetentionPolicy(; keep_ancestor_objects = true, keep_uncommitted_runs = true),
    )
    @test find_object(wide.graph, ObjectId(ID_SECTOR), r0) !== nothing
    @test find_run(wide.graph, RunId("run-failed")) !== nothing
    @test wide.plan.duplicated_content >= 1
end

@testset "log stream root keeps the selected debug stream" begin
    graph, _, r1, _, _, _ = _purge_fixture()
    roots = [RetentionRoot(r1), RetentionRoot(RunId("run-failed"), :stderr)]
    result = compact_archive(graph, roots)
    compacted = result.graph
    @test compacted !== nothing
    @test any(
        s -> s.run_id == RunId("run-failed") && s.kind === :stderr && s.retention === :debug,
        compacted.log_streams,
    )
    @test find_run(compacted, RunId("run-failed")) !== nothing
    @test_throws ArgumentError plan_purge(graph, [RetentionRoot(RunId("run-failed"), :trace)])
    @test_throws ArgumentError plan_purge(
        graph,
        [RetentionRoot(; kind = :log_stream, run_id = RunId("run-failed"))],
    )
end

@testset "object root keeps only that version's reference closure" begin
    graph, r0, r1, _, _, _ = _purge_fixture()
    sibling = _obj(:example, "volume", ID_VOL, REV_2; content = "hash-v")
    graph = _graph_with(graph; objects = vcat(graph.objects, [sibling]))
    result = compact_archive(graph, [RetentionRoot(ObjectId(ID_SECTOR), r1)])
    compacted = result.graph
    @test compacted !== nothing
    @test find_object(compacted, ObjectId(ID_SECTOR), r1) !== nothing
    @test find_object(compacted, ObjectId(ID_GEOM), r0) !== nothing
    @test find_object(compacted, ObjectId(ID_VOL), r1) === nothing
    @test find_object(compacted, ObjectId(ID_SECTOR), r0) === nothing
    revision_root = compact_archive(graph, [RetentionRoot(r1)])
    @test find_object(revision_root.graph, ObjectId(ID_VOL), r1) !== nothing
end

@testset "pinned events survive as roots with required object refs" begin
    graph, _, r1, r2, _, _ = _purge_fixture()
    helper = _obj(:example, "volume", ID_VOL, REV_3; content = "hash-v")
    pinned = EventRecord(
        :evidence,
        RunId("run-failed");
        sequence = 0,
        retention = :pinned,
        object_refs = [ObjectRef(ObjectId(ID_VOL), r2)],
    )
    graph = _graph_with(
        graph;
        objects = vcat(graph.objects, [helper]),
        events = vcat(graph.events, [pinned]),
    )
    result = compact_archive(graph, [RetentionRoot(r1)])
    compacted = result.graph
    @test compacted !== nothing
    @test find_run(compacted, RunId("run-failed")) !== nothing
    @test any(e -> e.retention === :pinned && e.run_id == RunId("run-failed"), compacted.events)
    @test find_object(compacted, ObjectId(ID_VOL), r2) !== nothing
end

@testset "retained runs close over parent_run_id" begin
    graph, _, r1, _, _, run = _purge_fixture()
    parent = RunRecord(RunId("run-parent"); status = :failed)
    child = _run_with(run; parent_run_id = parent.id)
    graph = _graph_with(
        graph;
        runs = vcat([r.id == run.id ? child : r for r in graph.runs], [parent]),
    )
    result = compact_archive(graph, [RetentionRoot(r1)])
    compacted = result.graph
    @test compacted !== nothing
    @test find_run(compacted, run.id) !== nothing
    @test find_run(compacted, parent.id) !== nothing
end

@testset "retained activity refs keep objects outside inspect closure" begin
    graph, _, r1, r2, _, run = _purge_fixture()
    @test select(inspect(graph, r1), ObjectId(ID_MESH)) === nothing
    activity = ActivityRecord(
        ActivityId("act-1"),
        run.id,
        Symbol("example/step");
        used = [ArchiveReference(:mesh, ObjectId(ID_MESH); revision_id = r2)],
    )
    child = _run_with(run; activities = [activity])
    graph = _graph_with(graph; runs = [r.id == run.id ? child : r for r in graph.runs])
    result = compact_archive(graph, [RetentionRoot(r1)])
    compacted = result.graph
    @test compacted !== nothing
    @test find_object(compacted, ObjectId(ID_MESH), r2) !== nothing
    @test select(inspect(compacted, r1), ObjectId(ID_MESH)) === nothing
end

@testset "invalid purge plan blocks compacted graph publication" begin
    graph, _, r1, _, _, run = _purge_fixture()
    missing = ObjectId("missing-activity-object")
    activity = ActivityRecord(
        ActivityId("act-1"),
        run.id,
        Symbol("example/step");
        used = [ArchiveReference(:missing, missing)],
    )
    child = _run_with(run; activities = [activity])
    graph = _graph_with(graph; runs = [r.id == run.id ? child : r for r in graph.runs])

    plan = plan_purge(graph, [RetentionRoot(r1)])
    @test !isvalid(validate(plan))
    @test any(d -> d.code === :missing_activity_object, plan.diagnostics)

    result = compact_archive(graph, [RetentionRoot(r1)])
    @test result.source_unchanged
    @test result.graph === nothing
    @test !isvalid(result.report)
    @test any(d -> d.code === :missing_activity_object, result.report.diagnostics)
    @test !isready(readiness(result, PipelineTarget(:inspect)))
end
