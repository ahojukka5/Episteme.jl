@testset "plan/run/activity/event/revision records" begin
    @test isdefined(Episteme, :OperationSpec)
    @test isdefined(Episteme, :Plan)
    @test isdefined(Episteme, :RunRecord)
    @test isdefined(Episteme, :ActivityRecord)
    @test isdefined(Episteme, :EventRecord)
    @test isdefined(Episteme, :RevisionRecord)
    @test :Plan in names(Episteme)
    @test EPISTEME_PLAN_KIND === Symbol("episteme/plan")
    @test EPISTEME_DOCUMENT_KIND === Symbol("episteme/document")
    @test schema_kind(episteme_plan_schema()) === EPISTEME_PLAN_KIND
    @test schema_kind(episteme_document_schema("2.0.0")) === EPISTEME_DOCUMENT_KIND

    spec = OperationSpec(
        Symbol("example/step");
        inputs = (:geometry,),
        outputs = (:mesh,),
        effects = (:filesystem,),
        default_reuse = :forbid,
        idempotency_key = "job-1",
    )
    @test spec.kind === Symbol("example/step")
    @test spec.idempotency_key == "job-1"
    @test to_namedtuple(spec).effects === (:filesystem,)
    @test_throws ArgumentError OperationSpec(Symbol("example/step"); default_reuse = :maybe)

    plan = Plan(
        PlanId("plan-1");
        document_id = DocumentId("doc-1"),
        operations = [spec],
    )
    @test plan.document_id == DocumentId("doc-1")
    @test isvalid(validate(plan))
    @test to_namedtuple(plan).id == "plan-1"
    @test_throws ArgumentError Plan(PlanId("p"); schema = SchemaRef(:example, "other", "1.0.0"))

    activity = ActivityRecord(
        ActivityId("act-1"),
        RunId("run-1"),
        Symbol("example/step");
        idempotency_key = "job-1",
        reuse = :computed,
    )
    @test activity.id != activity.idempotency_key
    @test activity.idempotency_key == "job-1"

    failed = RunRecord(
        RunId("run-failed");
        plan_id = plan.id,
        status = :failed,
    )
    @test failed.revision_id === nothing
    @test failed.status === :failed

    committed_run = RunRecord(
        RunId("run-1");
        plan_id = plan.id,
        revision_id = RevisionId(REV_1),
        status = :completed,
        activities = [activity],
    )
    rev = RevisionRecord(
        RevisionId(REV_1);
        run_id = committed_run.id,
        plan_id = plan.id,
    )
    @test !hasfield(typeof(rev), :objects)
    @test !hasfield(typeof(rev), :object_ids)

    event = EventRecord(:heartbeat, committed_run.id; activity_id = activity.id, payload = (; n = 1))
    obj = _obj(:example, "model-state", ID_SECTOR, REV_1)
    graph = ArchiveGraph(
        [obj];
        heads = [WorkflowHead(WorkflowHeadId("head-1"), :main, RevisionId(REV_1))],
        revisions = [rev],
        runs = [committed_run, failed],
        events = [event],
    )
    @test isvalid(validate(graph))
    @test find_revision(graph, RevisionId(REV_1)) === rev
    @test find_run(graph, RunId("run-failed")).revision_id === nothing
    @test find_objects(graph, RevisionId(REV_1)) == [obj]
    nt = to_namedtuple(graph)
    @test nt.runs[1].status === :completed || nt.runs[2].status === :completed
    @test nt.events[1].kind === :heartbeat
    @test report(graph).metadata.runs == 2
    @test occursin("revisions=1", sprint(show, graph))

    empty_key = OperationSpec(Symbol("example/other"); idempotency_key = "  ")
    @test empty_key.idempotency_key === nothing
end

@testset "history records validate cross-references" begin
    obj = _obj(:example, "model-state", ID_SECTOR, REV_1)
    rev = RevisionRecord(RevisionId(REV_1); run_id = RunId("run-1"))
    activity = ActivityRecord(ActivityId("act-1"), RunId("run-1"), Symbol("example/step"))
    run = RunRecord(
        RunId("run-1");
        revision_id = RevisionId(REV_1),
        status = :completed,
        activities = [activity],
    )

    dup_rev = validate(ArchiveGraph(
        [obj];
        revisions = [rev, RevisionRecord(RevisionId(REV_1))],
        runs = [run],
    ))
    @test any(d -> d.code === :duplicate_revision, dup_rev.diagnostics)

    missing_rev = validate(ArchiveGraph(
        [obj];
        revisions = [RevisionRecord(RevisionId(REV_2))],
        runs = [RunRecord(RunId("run-x"))],
    ))
    @test any(d -> d.code === :missing_revision_record, missing_rev.diagnostics)

    mismatch = validate(ArchiveGraph(
        [obj];
        revisions = [RevisionRecord(RevisionId(REV_1); run_id = RunId("other"))],
        runs = [run],
    ))
    @test any(d -> d.code === :run_revision_mismatch, mismatch.diagnostics)

    wrong_home = ActivityRecord(ActivityId("act-x"), RunId("other"), Symbol("example/step"))
    bad_activity = validate(ArchiveGraph(
        [obj];
        revisions = [rev],
        runs = [RunRecord(RunId("run-1"); revision_id = RevisionId(REV_1), activities = [wrong_home])],
    ))
    @test any(d -> d.code === :activity_run_mismatch, bad_activity.diagnostics)

    dangling_event = validate(ArchiveGraph(
        [obj];
        revisions = [rev],
        runs = [run],
        events = [EventRecord(:log, RunId("missing"))],
    ))
    @test any(d -> d.code === :missing_event_run, dangling_event.diagnostics)

    dangling_act_event = validate(ArchiveGraph(
        [obj];
        revisions = [rev],
        runs = [run],
        events = [EventRecord(:log, run.id; activity_id = ActivityId("nope"))],
    ))
    @test any(d -> d.code === :missing_event_activity, dangling_act_event.diagnostics)

    orphan_head = validate(ArchiveGraph(
        [obj];
        heads = [WorkflowHead(WorkflowHeadId("h"), :main, RevisionId(REV_2))],
        revisions = [rev],
        runs = [run],
    ))
    @test any(d -> d.code === :dangling_workflow_head, orphan_head.diagnostics)
end
