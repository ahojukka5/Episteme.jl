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
