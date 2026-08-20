# Durable run / commit / restart contract (#27). No execute!/commit!, no I/O.

function _staged(
    object::AbstractString,
    schema_id::AbstractString;
    origin = :generated,
    content = nothing,
    source = nothing,
    activity = nothing,
    namespace = :example,
    provenance = ProvenanceRefs(),
    references = ArchiveReference[],
)
    ns = _ns(namespace; display = String(namespace) * ".jl")
    kind = schema_kind(namespace, schema_id)
    return StagedObject(
        ObjectId(object);
        namespace = ns,
        kind = kind,
        schema = SchemaRef(namespace, schema_id, "1.0.0"),
        origin = origin,
        content_id = content === nothing ? nothing : ContentId(content),
        source_revision_id = source === nothing ? nothing : RevisionId(source),
        activity_id = activity === nothing ? nothing : ActivityId(activity),
        provenance = provenance,
        references = references,
    )
end

@testset "run status vocabulary includes incomplete states" begin
    @test RUN_STATUSES === (
        :queued, :running, :completed, :failed, :interrupted, :cancelled, :uncertain,
    )
    @test :cancelled in RUN_STATUSES
    @test :uncertain in RUN_STATUSES
    for status in (:queued, :running, :failed, :interrupted, :cancelled, :uncertain)
        run = RunRecord(RunId("run-$status"); status = status)
        @test run.revision_id === nothing
        @test isvalid(validate(run))
        @test !isready(readiness(run, PipelineTarget(:commit)))
    end
    @test_throws ArgumentError RunRecord(RunId("bad"); status = :success)
    @test_throws ArgumentError WriteTransaction(; scope = :file, phase = :begin, sequence = 0)
    @test_throws ArgumentError WriteTransaction(; scope = :run, phase = :begin, sequence = 0)
    @test_throws ArgumentError StagedObject(
        ObjectId(ID_SECTOR);
        namespace = _ns(:example),
        kind = Symbol("example/model-state"),
        schema = SchemaRef(:example, "model-state", "1.0.0"),
        origin = :copied,
    )
end

@testset "interrupted run is inspectable and is not a revision" begin
    activity = ActivityRecord(ActivityId("act-1"), RunId("run-int"), Symbol("example/step"))
    staged = _staged(ID_SECTOR, "model-state"; content = "hash-live", activity = "act-1")
    run = RunRecord(
        RunId("run-int");
        status = :interrupted,
        activities = [activity],
        staged = [staged],
        restart = RestartRequirement(;
            checkpoints = [CheckpointRef(
                ObjectId(ID_SECTOR);
                content_id = ContentId("hash-live"),
                kind = Symbol("example/solver-state"),
            )],
            from_activity_id = activity.id,
        ),
    )
    event = EventRecord(
        :checkpoint,
        run.id;
        activity_id = activity.id,
        sequence = 1,
        source = "rank-0",
        payload = (; note = "wrote checkpoint"),
    )
    parent = _obj(:example, "model-state", ID_SECTOR, REV_1; content = "hash-root")
    graph = ArchiveGraph(
        [parent];
        heads = [WorkflowHead(WorkflowHeadId("head-1"), :main, RevisionId(REV_1))],
        revisions = [RevisionRecord(RevisionId(REV_1))],
        runs = [run],
        events = [event],
        writes = [WriteTransaction(;
            scope = :run,
            phase = :appending,
            sequence = 1,
            run_id = run.id,
            writer_token = "writer-1",
        )],
    )
    @test isvalid(validate(graph))
    @test run.revision_id === nothing
    @test find_revision(graph, RevisionId(REV_2)) === nothing
    @test find_objects(graph, RevisionId(REV_1)) == [parent]
    @test report(run).metadata.committed === false
    @test occursin("interrupted", report(run).summary)
    @test !isready(readiness(run, PipelineTarget(:commit)))
    @test isready(readiness(run, PipelineTarget(:restart)))
    @test find_write(graph; scope = :run, run_id = run.id).phase === :appending
end

@testset "failed run keeps events without a revision" begin
    run = RunRecord(RunId("run-fail"); status = :failed)
    events = [
        EventRecord(:log, run.id; sequence = 0, source = "rank-0", payload = (; msg = "start")),
        EventRecord(:error, run.id; sequence = 1, source = "rank-0", payload = (; msg = "boom")),
    ]
    graph = ArchiveGraph(ArchiveObject[]; runs = [run], events = events)
    @test isvalid(validate(graph))
    @test run.revision_id === nothing
    @test length(ordered_run_events(graph, run.id)) == 2
    @test ordered_run_events(graph, run.id)[2].kind === :error
    @test !isready(readiness(run, PipelineTarget(:commit)))
end

@testset "completed execute then explicit commit promotes staging once" begin
    parent_obj = _obj(:example, "model-state", ID_SECTOR, REV_1; content = "hash-x")
    parent_rev = RevisionRecord(RevisionId(REV_1))
    activity = ActivityRecord(ActivityId("act-1"), RunId("run-ok"), Symbol("example/step"))
    reused = _staged(
        ID_SECTOR,
        "model-state";
        origin = :reused,
        content = "hash-x",
        source = REV_1,
        activity = "act-1",
    )
    generated = _staged(ID_MESH, "mesh"; content = "hash-mesh", activity = "act-1")
    executed = RunRecord(
        RunId("run-ok");
        status = :completed,
        activities = [activity],
        staged = [reused, generated],
    )
    before = ArchiveGraph(
        [parent_obj];
        heads = [WorkflowHead(WorkflowHeadId("head-1"), :main, RevisionId(REV_1))],
        revisions = [parent_rev],
        runs = [executed],
        events = [EventRecord(:done, executed.id; sequence = 1)],
    )
    @test isvalid(validate(before))
    @test isready(readiness(executed, PipelineTarget(:commit)))
    @test isready(readiness(before, PipelineTarget(:commit; run_id = executed.id)))
    @test executed.revision_id === nothing

    new_rev = RevisionId(REV_2)
    promoted = promote_staged(executed, new_rev)
    @test length(promoted) == 2
    @test promoted[1].revision_id == new_rev
    @test promoted[1].object_id == parent_obj.object_id
    @test promoted[1].content_id == parent_obj.content_id
    @test promoted[1] !== parent_obj
    committed_run = RunRecord(
        executed.id;
        status = :completed,
        revision_id = new_rev,
        activities = executed.activities,
        staged = executed.staged,
    )
    rec = RevisionRecord(new_rev; parents = [RevisionId(REV_1)], run_id = committed_run.id)
    after = ArchiveGraph(
        vcat(before.objects, promoted);
        heads = [WorkflowHead(WorkflowHeadId("head-1"), :main, new_rev)],
        revisions = vcat(before.revisions, [rec]),
        runs = [committed_run],
        events = before.events,
        writes = [WriteTransaction(;
            scope = :archive,
            phase = :committed,
            sequence = 2,
            run_id = committed_run.id,
            writer_token = "writer-1",
        )],
    )
    @test isvalid(validate(after))
    @test length(after.revisions) == length(before.revisions) + 1
    @test after.heads[1].revision_id == new_rev
    @test before.heads[1].revision_id == RevisionId(REV_1)
    @test before.objects == [parent_obj]
    @test find_objects(after, RevisionId(REV_1)) == [parent_obj]
    @test Set(obj.object_id for obj in find_objects(after, new_rev)) ==
        Set([ObjectId(ID_SECTOR), ObjectId(ID_MESH)])
    @test !isready(readiness(committed_run, PipelineTarget(:commit)))
    @test any(d -> d.code === :run_already_committed,
        readiness(committed_run, PipelineTarget(:commit)).diagnostics)
end

@testset "restart requirement names exact object and content" begin
    checkpoint = _obj(
        :example, "model-state", ID_SECTOR, REV_1;
        content = "hash-ckpt",
        provenance = ProvenanceRefs(; execution_context = ExecutionContextId("ctx-1")),
    )
    activity = ActivityRecord(ActivityId("act-1"), RunId("run-rst"), Symbol("example/step"))
    run = RunRecord(
        RunId("run-rst");
        status = :failed,
        execution_context = ExecutionContextId("ctx-1"),
        activities = [activity],
        restart = RestartRequirement(;
            checkpoints = [CheckpointRef(
                ObjectId(ID_SECTOR);
                content_id = ContentId("hash-ckpt"),
                revision_id = RevisionId(REV_1),
                kind = Symbol("example/solver-state"),
            )],
            execution_context = ExecutionContextId("ctx-1"),
            from_activity_id = activity.id,
        ),
    )
    graph = ArchiveGraph(
        [checkpoint];
        revisions = [RevisionRecord(RevisionId(REV_1))],
        runs = [run],
    )
    @test isvalid(validate(graph))
    ready = readiness(graph, PipelineTarget(:restart; run_id = run.id))
    @test isready(ready)
    @test to_namedtuple(run.restart).checkpoints[1].content_id == "hash-ckpt"
end

@testset "missing or incompatible restart state is diagnostic, not guessed" begin
    present = _obj(:example, "model-state", ID_SECTOR, REV_1; content = "hash-a")
    missing = RunRecord(
        RunId("run-missing");
        status = :interrupted,
        restart = RestartRequirement(;
            checkpoints = [CheckpointRef(ObjectId(ID_MESH); content_id = ContentId("hash-mesh"))],
        ),
    )
    missing_graph = ArchiveGraph(
        [present];
        revisions = [RevisionRecord(RevisionId(REV_1))],
        runs = [missing],
    )
    missing_ready = readiness(missing_graph, PipelineTarget(:restart; run_id = missing.id))
    @test !isready(missing_ready)
    @test any(d -> d.code === :missing_restart_checkpoint, missing_ready.diagnostics)

    mismatch = RunRecord(
        RunId("run-mismatch");
        status = :interrupted,
        restart = RestartRequirement(;
            checkpoints = [CheckpointRef(
                ObjectId(ID_SECTOR);
                content_id = ContentId("hash-other"),
                revision_id = RevisionId(REV_1),
            )],
        ),
    )
    mismatch_graph = ArchiveGraph(
        [present];
        revisions = [RevisionRecord(RevisionId(REV_1))],
        runs = [mismatch],
    )
    mismatch_ready = readiness(mismatch_graph, PipelineTarget(:restart; run_id = mismatch.id))
    @test !isready(mismatch_ready)
    @test any(d -> d.code === :incompatible_restart_content, mismatch_ready.diagnostics)

    undeclared = RunRecord(RunId("run-none"); status = :interrupted)
    @test any(d -> d.code === :restart_not_declared,
        readiness(undeclared, PipelineTarget(:restart)).diagnostics)

    unverifiable = _obj(:example, "model-state", ID_SECTOR, REV_1)
    @test unverifiable.content_id === nothing
    unknown = RunRecord(
        RunId("run-unknown");
        status = :interrupted,
        restart = RestartRequirement(;
            checkpoints = [CheckpointRef(
                ObjectId(ID_SECTOR);
                content_id = ContentId("hash-ckpt"),
                revision_id = RevisionId(REV_1),
            )],
        ),
    )
    unknown_graph = ArchiveGraph(
        [unverifiable];
        revisions = [RevisionRecord(RevisionId(REV_1))],
        runs = [unknown],
    )
    unknown_ready = readiness(unknown_graph, PipelineTarget(:restart; run_id = unknown.id))
    @test !isready(unknown_ready)
    @test any(d -> d.code === :unverified_restart_content, unknown_ready.diagnostics)
end

@testset "incomplete status cannot masquerade as a committed revision" begin
    obj = _obj(:example, "model-state", ID_SECTOR, REV_1)
    for status in (:failed, :interrupted, :cancelled, :running, :queued, :uncertain)
        run = RunRecord(RunId("run-bad"); status = status, revision_id = RevisionId(REV_1))
        report = validate(run)
        @test !isvalid(report)
        @test any(d -> d.code in (:incomplete_run_has_revision, :uncertain_run_has_revision),
            report.diagnostics)
    end

    leaked = validate(ArchiveGraph(
        [obj];
        revisions = [RevisionRecord(RevisionId(REV_1); run_id = RunId("run-open"))],
        runs = [RunRecord(RunId("run-open"); status = :interrupted)],
    ))
    @test any(d -> d.code === :uncommitted_run_has_revision, leaked.diagnostics)
end

@testset "staging, reuse, and committed promotion diagnostics" begin
    parent = _obj(:example, "model-state", ID_SECTOR, REV_1; content = "hash-x")
    reused = _staged(ID_SECTOR, "model-state"; origin = :reused, content = "hash-x", source = REV_1)
    generated = _staged(ID_MESH, "mesh"; content = "hash-mesh")
    committed = RunRecord(
        RunId("run-1");
        status = :completed,
        revision_id = RevisionId(REV_2),
        staged = [reused, generated],
    )
    missing = validate(ArchiveGraph(
        [parent];
        revisions = [
            RevisionRecord(RevisionId(REV_1)),
            RevisionRecord(RevisionId(REV_2); run_id = committed.id),
        ],
        runs = [committed],
    ))
    @test any(d -> d.code === :staged_not_promoted, missing.diagnostics)

    wrong_source = _staged(
        ID_MESH, "mesh"; origin = :reused, content = "hash-mesh", source = REV_1,
    )
    dangling_reuse = validate(ArchiveGraph(
        [parent];
        revisions = [RevisionRecord(RevisionId(REV_1))],
        runs = [RunRecord(RunId("run-re"); status = :completed, staged = [wrong_source])],
    ))
    @test any(d -> d.code === :reused_source_missing, dangling_reuse.diagnostics)

    content_mismatch = _staged(
        ID_SECTOR, "model-state"; origin = :reused, content = "hash-y", source = REV_1,
    )
    mismatch = validate(ArchiveGraph(
        [parent];
        revisions = [RevisionRecord(RevisionId(REV_1))],
        runs = [RunRecord(RunId("run-c"); status = :completed, staged = [content_mismatch])],
    ))
    @test any(d -> d.code === :reused_content_mismatch, mismatch.diagnostics)

    dropped = _staged(ID_SECTOR, "model-state"; origin = :reused, source = REV_1)
    @test dropped.content_id === nothing
    dropped_run = RunRecord(RunId("run-drop"); status = :completed, staged = [dropped])
    dropped_graph = ArchiveGraph(
        [parent];
        revisions = [RevisionRecord(RevisionId(REV_1))],
        runs = [dropped_run],
    )
    dropped_report = validate(dropped_graph)
    @test !isvalid(dropped_report)
    @test any(d -> d.code === :reused_content_missing, dropped_report.diagnostics)
    dropped_ready = readiness(dropped_graph, PipelineTarget(:commit; run_id = dropped_run.id))
    @test isready(readiness(dropped_run, PipelineTarget(:commit)))
    @test !isready(dropped_ready)
    @test any(d -> d.code === :reused_content_missing, dropped_ready.diagnostics)

    dangling_ready = readiness(
        ArchiveGraph(
            [parent];
            revisions = [RevisionRecord(RevisionId(REV_1))],
            runs = [RunRecord(RunId("run-re"); status = :completed, staged = [wrong_source])],
        ),
        PipelineTarget(:commit; run_id = RunId("run-re")),
    )
    @test !isready(dangling_ready)
    @test any(d -> d.code === :reused_source_missing, dangling_ready.diagnostics)
end

@testset "write transactions, single-writer, and fail-closed uncertain outcome" begin
    run = RunRecord(RunId("run-w"); status = :running)
    in_flight = WriteTransaction(;
        scope = :archive,
        phase = :committing,
        sequence = 1,
        run_id = run.id,
        writer_token = "a",
    )
    other = WriteTransaction(;
        scope = :archive,
        phase = :appending,
        sequence = 2,
        writer_token = "b",
    )
    multi = validate(ArchiveGraph(ArchiveObject[]; runs = [run], writes = [in_flight, other]))
    @test any(d -> d.code === :multiple_archive_writers, multi.diagnostics)

    no_token = validate(WriteTransaction(; scope = :archive, phase = :appending, sequence = 0))
    @test any(d -> d.code === :missing_writer_token, no_token.diagnostics)

    uncertain = RunRecord(RunId("run-u"); status = :uncertain)
    tx = WriteTransaction(;
        scope = :run,
        phase = :uncertain,
        sequence = 3,
        run_id = uncertain.id,
        writer_token = "w",
    )
    graph = ArchiveGraph(ArchiveObject[]; runs = [uncertain], writes = [tx])
    @test isvalid(validate(graph))
    ready = readiness(graph, PipelineTarget(:commit; run_id = uncertain.id))
    @test !isready(ready)
    @test any(d -> d.code === :uncertain_side_effect, ready.diagnostics)

    committed_in_flight = RunRecord(
        RunId("run-w");
        status = :completed,
        revision_id = RevisionId(REV_1),
    )
    bad = validate(ArchiveGraph(
        [_obj(:example, "model-state", ID_SECTOR, REV_1)];
        revisions = [RevisionRecord(RevisionId(REV_1); run_id = committed_in_flight.id)],
        runs = [committed_in_flight],
        writes = [WriteTransaction(;
            scope = :run,
            phase = :committing,
            sequence = 1,
            run_id = committed_in_flight.id,
            writer_token = "a",
        )],
    ))
    @test any(d -> d.code === :in_flight_write_has_revision, bad.diagnostics)

    ready_run = RunRecord(RunId("run-ok"); status = :completed)
    global_writer = WriteTransaction(;
        scope = :archive,
        phase = :appending,
        sequence = 7,
        writer_token = "other",
    )
    blocked = ArchiveGraph(
        ArchiveObject[];
        runs = [ready_run],
        writes = [global_writer],
    )
    @test isvalid(validate(blocked))
    @test isready(readiness(ready_run, PipelineTarget(:commit)))
    blocked_ready = readiness(blocked, PipelineTarget(:commit; run_id = ready_run.id))
    @test !isready(blocked_ready)
    @test any(d -> d.code === :in_flight_write, blocked_ready.diagnostics)
end

@testset "source-local event sequence is the causal order" begin
    run = RunRecord(RunId("run-seq"); status = :running)
    late = EventRecord(:b, run.id; sequence = 2, source = "rank-0")
    early = EventRecord(:a, run.id; sequence = 1, source = "rank-0")
    other = EventRecord(:c, run.id; sequence = 1, source = "rank-1")
    graph = ArchiveGraph(ArchiveObject[]; runs = [run], events = [late, early, other])
    @test isvalid(validate(graph))
    ordered = ordered_run_events(graph, run.id)
    @test [e.kind for e in ordered] == [:a, :b, :c]
    @test ordered[1].sequence == 1
    @test ordered[1].source == "rank-0"

    dup = validate(ArchiveGraph(
        ArchiveObject[];
        runs = [run],
        events = [
            EventRecord(:a, run.id; sequence = 1, source = "rank-0"),
            EventRecord(:b, run.id; sequence = 1, source = "rank-0"),
        ],
    ))
    @test any(d -> d.code === :duplicate_event_sequence, dup.diagnostics)
end

@testset "promote_staged preserves envelope provenance and references" begin
    parent_id = ObjectId(ID_GEOM)
    staged = _staged(
        ID_MESH,
        "mesh";
        content = "hash-mesh",
        provenance = ProvenanceRefs(;
            software_environment = SoftwareEnvironmentId("env-1"),
            execution_context = ExecutionContextId("ctx-1"),
        ),
        references = [ArchiveReference(:geometry, parent_id; revision_id = RevisionId(REV_1))],
    )
    run = RunRecord(RunId("run-env"); status = :completed, staged = [staged])
    promoted = promote_staged(run, RevisionId(REV_2))
    @test length(promoted) == 1
    obj = promoted[1]
    @test obj.provenance.software_environment == SoftwareEnvironmentId("env-1")
    @test obj.provenance.execution_context == ExecutionContextId("ctx-1")
    @test length(obj.references) == 1
    @test obj.references[1].name === :geometry
    @test obj.references[1].target.object_id == parent_id
    @test obj.references[1].target.revision_id == RevisionId(REV_1)
    @test obj.run_id == run.id
    @test to_namedtuple(staged).references[1].name === :geometry
end

@testset "lifecycle records serialize and do not overwrite committed history" begin
    staged = _staged(ID_SECTOR, "model-state"; origin = :generated, content = "hash-x")
    run = RunRecord(RunId("run-s"); status = :completed, staged = [staged])
    @test to_namedtuple(run).staged[1].origin === :generated
    @test to_namedtuple(run).restart === nothing
    tx = WriteTransaction(; scope = :archive, phase = :aborted, sequence = 4, writer_token = "w")
    @test to_namedtuple(tx).phase === :aborted
    @test to_namedtuple(CheckpointRef(ObjectId(ID_SECTOR); kind = :solver)).kind === :solver

    parent = _obj(:example, "model-state", ID_SECTOR, REV_1; content = "hash-x")
    graph = ArchiveGraph(
        [parent];
        heads = [WorkflowHead(WorkflowHeadId("head-1"), :main, RevisionId(REV_1))],
        revisions = [RevisionRecord(RevisionId(REV_1))],
        runs = [run],
        writes = [tx],
    )
    moved = ArchiveGraph(
        graph.objects;
        heads = [WorkflowHead(WorkflowHeadId("head-1"), :main, RevisionId(REV_1))],
        revisions = graph.revisions,
        runs = graph.runs,
        events = graph.events,
        writes = graph.writes,
    )
    @test moved.objects === graph.objects || moved.objects == graph.objects
    @test moved.revisions == graph.revisions
    @test to_namedtuple(graph).writes[1].sequence == 4
    @test :StagedObject in names(Episteme)
    @test :WriteTransaction in names(Episteme)
    @test :promote_staged in names(Episteme)
end
