# Durable event timeline and optional log streams (#44). No file I/O.

@testset "event timeline columns are generic and sequence-ordered" begin
    activity = ActivityRecord(ActivityId("act-1"), RunId("run-1"), Symbol("example/step"))
    obj = _obj(:example, "model-state", ID_SECTOR, REV_1; content = "hash-x")
    run = RunRecord(
        RunId("run-1");
        status = :completed,
        revision_id = RevisionId(REV_1),
        activities = [activity],
        agent_id = AgentId("agent-1"),
    )
    late_clock = EventRecord(
        :checkpoint,
        run.id;
        activity_id = activity.id,
        sequence = 1,
        source = "rank-0",
        severity = :info,
        message = "wrote solver state",
        timestamp = "2026-08-20T12:00:02Z",
        scope = :example,
        revision_id = RevisionId(REV_1),
        object_refs = [ObjectRef(ObjectId(ID_SECTOR), RevisionId(REV_1))],
        producer_id = AgentId("agent-1"),
    )
    early_clock = EventRecord(
        :start,
        run.id;
        activity_id = activity.id,
        sequence = 0,
        source = "rank-0",
        severity = :info,
        message = "activity started",
        timestamp = "2026-08-20T12:00:09Z",
        scope = :example,
    )
    graph = ArchiveGraph(
        [obj];
        revisions = [RevisionRecord(RevisionId(REV_1); run_id = run.id)],
        runs = [run],
        events = [late_clock, early_clock],
    )
    @test isvalid(validate(graph))
    ordered = ordered_run_events(graph, run.id)
    @test [e.kind for e in ordered] == [:start, :checkpoint]
    rows = event_timeline(graph; run_id = run.id)
    @test length(rows) == 2
    @test rows[1].kind === :start
    @test rows[1].sequence == 0
    @test rows[2].timestamp == "2026-08-20T12:00:02Z"
    @test rows[2].scope === :example
    @test rows[2].severity === :info
    @test rows[2].message == "wrote solver state"
    @test rows[2].activity_id == "act-1"
    @test rows[2].revision_id == REV_1
    @test rows[2].object_ids == (ID_SECTOR,)
    @test rows[2].source == "rank-0"
    nt = to_namedtuple(late_clock)
    @test nt.severity === :info
    @test nt.retention === :forensic
    @test :EventBatch in names(Episteme)
    @test :LogStreamRecord in names(Episteme)
    @test :event_timeline in names(Episteme)
end

@testset "failed uncommitted run keeps events without a revision" begin
    run = RunRecord(RunId("run-fail"); status = :failed)
    events = [
        EventRecord(:log, run.id; sequence = 0, source = "rank-0", message = "start"),
        EventRecord(
            :error,
            run.id;
            sequence = 1,
            source = "rank-0",
            severity = :error,
            message = "solve failed",
        ),
    ]
    graph = ArchiveGraph(ArchiveObject[]; runs = [run], events = events)
    @test isvalid(validate(graph))
    @test run.revision_id === nothing
    @test isempty(graph.revisions)
    @test length(event_timeline(graph; run_id = run.id)) == 2
    @test event_timeline(graph; run_id = run.id)[2].severity === :error
end

@testset "event batch is one metadata transaction" begin
    run = RunRecord(RunId("run-many"); status = :running)
    events = EventRecord[
        EventRecord(:tick, run.id; sequence = i, source = "rank-0", message = "n=$i")
        for i in 0:999
    ]
    write = WriteTransaction(;
        scope = :run,
        phase = :appending,
        sequence = 1,
        run_id = run.id,
        writer_token = "writer-1",
    )
    batch = EventBatch(events; write = write)
    @test isvalid(validate(batch))
    @test length(batch.events) == 1000
    @test to_namedtuple(batch).count == 1000
    @test to_namedtuple(batch).write.sequence == 1
    graph = ArchiveGraph(ArchiveObject[]; runs = [run], events = events, writes = [write])
    @test isvalid(validate(graph))
    @test length(graph.writes) == 1
    @test length(event_timeline(graph; run_id = run.id)) == 1000
end

@testset "optional log streams are independent of revisions" begin
    run = RunRecord(RunId("run-log"); status = :failed)
    stream = LogStreamRecord(
        run.id,
        :stderr;
        source = "rank-0",
        retention = :debug,
        content_id = ContentId("log-bytes-1"),
        summary = "solver stderr",
    )
    pinned = LogStreamRecord(run.id, :stdout; retention = :pinned, summary = "keep")
    graph = ArchiveGraph(
        ArchiveObject[];
        runs = [run],
        events = [EventRecord(:error, run.id; sequence = 0, severity = :error, message = "failed")],
        log_streams = [stream, pinned],
    )
    @test isvalid(validate(graph))
    @test run.revision_id === nothing
    @test length(ordered_log_streams(graph)) == 2
    @test to_namedtuple(stream).retention === :debug

    purged = ArchiveGraph(
        graph.objects;
        revisions = graph.revisions,
        runs = graph.runs,
        events = graph.events,
        log_streams = [pinned],
    )
    @test purged.objects == graph.objects
    @test purged.revisions == graph.revisions
    @test length(purged.log_streams) == 1
    @test purged.log_streams[1].retention === :pinned
end

@testset "credential-like event and log content is fail-closed" begin
    run = RunRecord(RunId("run-sec"); status = :running)
    secret_message = EventRecord(
        :log,
        run.id;
        message = "Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345",
    )
    @test any(d -> d.code === :credential_like_content, validate(secret_message).diagnostics)
    secret_key = EventRecord(:log, run.id; payload = (; api_token = "n/a"))
    @test any(d -> d.code === :credential_like_content, validate(secret_key).diagnostics)
    secret_stream = LogStreamRecord(
        run.id,
        :stdout;
        summary = "-----BEGIN RSA PRIVATE KEY-----\nMIIE",
    )
    @test any(d -> d.code === :credential_like_content, validate(secret_stream).diagnostics)

    graph = ArchiveGraph(ArchiveObject[]; runs = [run], events = [secret_message])
    @test any(d -> d.code === :credential_like_content, validate(graph).diagnostics)
end

@testset "event references validate; text is not scientific state" begin
    obj = _obj(:example, "model-state", ID_SECTOR, REV_1)
    run = RunRecord(RunId("run-1"); status = :failed)
    dangling = EventRecord(
        :note,
        run.id;
        object_refs = [ObjectId(ID_MESH)],
        message = "committed revision 2",
    )
    graph = ArchiveGraph(
        [obj];
        revisions = [RevisionRecord(RevisionId(REV_1))],
        runs = [run],
        events = [dangling],
    )
    report = validate(graph)
    @test any(d -> d.code === :dangling_event_object, report.diagnostics)
    @test run.revision_id === nothing
    @test dangling.message == "committed revision 2"
    @test dangling.revision_id === nothing

    missing_rev = validate(ArchiveGraph(
        [obj];
        revisions = [RevisionRecord(RevisionId(REV_1))],
        runs = [run],
        events = [EventRecord(:note, run.id; revision_id = RevisionId(REV_2))],
    ))
    @test any(d -> d.code === :missing_event_revision, missing_rev.diagnostics)

    @test_throws ArgumentError EventRecord(:log, run.id; severity = :fatal)
    @test_throws ArgumentError LogStreamRecord(run.id, :syslog)
end
