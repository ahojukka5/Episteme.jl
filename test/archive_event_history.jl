const EVENT_LOG_CONTENT = "sha256:" * repeat("f", 64)

function _event_history_fixture()
    graph, r0, r1, run = _run_history_fixture()
    activity_id = only(run.activities).id
    events = [
        EventRecord(
            :started,
            run.id;
            activity_id = activity_id,
            sequence = 1,
            source = "solver",
            severity = :info,
            message = "solver started",
            timestamp = "2026-08-31T00:00:00Z",
            scope = :run,
            revision_id = r1,
            object_refs = [ObjectRef(ObjectId(ID_GEOM); revision_id = r0)],
            producer_id = AgentId("agent-run-1"),
            execution_context = ExecutionContextId("ctx-run-1"),
            retention = :forensic,
            payload = (
                iteration = 1,
                metrics = (residual = 1.0,),
                tags = Dict(:phase => "solve", "backend" => "cpu"),
            ),
        ),
        EventRecord(
            :completed,
            run.id;
            activity_id = activity_id,
            sequence = 2,
            source = "solver",
            severity = :info,
            message = "solver completed",
            timestamp = "2026-08-31T00:00:01Z",
            scope = :run,
            revision_id = r1,
            object_refs = [ObjectRef(ObjectId(ID_MESH); revision_id = r1)],
            retention = :pinned,
            payload = (iterations = 2, converged = true),
        ),
    ]
    writes = [
        WriteTransaction(;
            scope = :run,
            phase = :committed,
            sequence = 1,
            run_id = run.id,
        ),
    ]
    streams = [
        LogStreamRecord(
            run.id,
            :stdout;
            activity_id = activity_id,
            source = "solver",
            retention = :forensic,
            content_id = ContentId(EVENT_LOG_CONTENT),
            summary = "solver stdout metadata",
        ),
    ]
    full = ArchiveGraph(
        graph.objects;
        heads = graph.heads,
        revisions = graph.revisions,
        runs = graph.runs,
        events = events,
        writes = writes,
        log_streams = streams,
    )
    return full, r0, r1
end

@testset "AH5 event history round-trips timeline writes and log metadata" begin
    mktempdir() do dir
        graph, _, revision_id = _event_history_fixture()
        schemas = SchemaRegistry([_mesh_def()])
        @test isvalid(validate(graph))

        path = joinpath(dir, "event-history.ah5")
        write_event_archive(path, graph; schemas = schemas)

        core = inspect_archive(path)
        @test core.identified
        @test AH5_STATE_HISTORY_FEATURE in core.profile.features
        @test AH5_RUN_HISTORY_FEATURE in core.profile.features
        @test AH5_EVENT_HISTORY_FEATURE in core.profile.features

        view = inspect_archive(path, ArchiveEventHistory)
        @test view.identified
        @test view.feature_declared
        @test isvalid(view)
        @test isvalid(validate(view))
        @test length(view.events) == 2
        @test length(view.writes) == 1
        @test length(view.log_streams) == 1

        original_timeline = event_timeline(graph)
        reopened_timeline = event_timeline(view)
        @test reopened_timeline == original_timeline

        @test Episteme._event_record_storage(view.events[1]).payload ==
            Episteme._event_record_storage(graph.events[1]).payload
        @test view.events[1].producer_id == AgentId("agent-run-1")
        @test view.events[1].execution_context == ExecutionContextId("ctx-run-1")
        @test view.writes[1].phase === :committed
        @test view.log_streams[1].content_id == ContentId(EVENT_LOG_CONTENT)
        @test view.log_streams[1].summary == "solver stdout metadata"

        reconstructed = reconstruct_graph(view)
        @test length(reconstructed.events) == 2
        @test length(reconstructed.writes) == 1
        @test length(reconstructed.log_streams) == 1
        @test isvalid(validate(reconstructed))

        manifest = inspect(view, revision_id)
        @test manifest.run !== nothing
        @test isready(readiness(manifest, PipelineTarget(:replay)))
        @test isready(readiness(manifest, PipelineTarget(:restart)))
        @test isready(readiness(manifest, PipelineTarget(:rerun)))

        raw_payload = JLD2.jldopen(path, "r"; plain = true) do file
            file["$(AH5_EVENT_HISTORY_KEY)/events/1"].payload
        end
        @test raw_payload.portable_kind === :namedtuple
    end
end

@testset "event persistence refuses nonportable and nested credential payloads" begin
    mktempdir() do dir
        graph, _, _ = _event_history_fixture()
        run = only(graph.runs)
        bad_event = EventRecord(
            :bad_payload,
            run.id;
            sequence = 3,
            source = "solver",
            payload = (bad = Ref(1),),
        )
        bad_graph = ArchiveGraph(
            graph.objects;
            heads = graph.heads,
            revisions = graph.revisions,
            runs = graph.runs,
            events = [bad_event],
        )
        path = joinpath(dir, "nonportable.ah5")
        @test_throws ArgumentError write_event_archive(
            path,
            bad_graph;
            schemas = SchemaRegistry([_mesh_def()]),
        )
        @test !ispath(path)

        secret_event = EventRecord(
            :secret_payload,
            run.id;
            sequence = 4,
            source = "solver",
            payload = (metadata = (api_key = "not-for-archive",),),
        )
        secret_graph = ArchiveGraph(
            graph.objects;
            heads = graph.heads,
            revisions = graph.revisions,
            runs = graph.runs,
            events = [secret_event],
        )
        secret_path = joinpath(dir, "secret.ah5")
        @test_throws ArgumentError write_event_archive(
            secret_path,
            secret_graph;
            schemas = SchemaRegistry([_mesh_def()]),
        )
        @test !ispath(secret_path)
    end
end

@testset "forensic event history rejects duplicate causal sequence" begin
    mktempdir() do dir
        graph, _, _ = _event_history_fixture()
        path = joinpath(dir, "duplicate-sequence.ah5")
        write_event_archive(path, graph; schemas = SchemaRegistry([_mesh_def()]))

        key = "$(AH5_EVENT_HISTORY_KEY)/events/2"
        JLD2.jldopen(path, "r+") do file
            raw = file[key]
            file[key] = merge(raw, (; sequence = 1))
        end

        view = inspect_archive(path, ArchiveEventHistory)
        @test view.identified
        @test view.feature_declared
        @test !isvalid(view)
        @test view.state === nothing
        @test isempty(view.events)
        @test any(d -> d.code === :duplicate_event_sequence, view.diagnostics)
        @test_throws ArgumentError reconstruct_graph(view)
    end
end

@testset "weak archived log identity is refused before publication" begin
    mktempdir() do dir
        graph, _, _ = _event_history_fixture()
        stream = only(graph.log_streams)
        weak_stream = LogStreamRecord(
            stream.run_id,
            stream.kind;
            activity_id = stream.activity_id,
            source = stream.source,
            retention = stream.retention,
            content_id = ContentId("legacy-log-id"),
            summary = stream.summary,
        )
        weak_graph = ArchiveGraph(
            graph.objects;
            heads = graph.heads,
            revisions = graph.revisions,
            runs = graph.runs,
            events = graph.events,
            writes = graph.writes,
            log_streams = [weak_stream],
        )
        path = joinpath(dir, "weak-log.ah5")
        @test_throws ArgumentError write_event_archive(
            path,
            weak_graph;
            schemas = SchemaRegistry([_mesh_def()]),
        )
        @test !ispath(path)
    end
end

@testset "run-history archives remain valid without event-history feature" begin
    mktempdir() do dir
        graph, _, _, _ = _run_history_fixture()
        path = joinpath(dir, "run-only.ah5")
        write_run_archive(path, graph; schemas = SchemaRegistry([_mesh_def()]))

        view = inspect_archive(path, ArchiveEventHistory)
        @test view.identified
        @test !view.feature_declared
        @test isvalid(view)
        @test view.state !== nothing
        @test length(view.runs) == 1
        @test isempty(view.events)
        @test isempty(view.writes)
        @test isempty(view.log_streams)
    end
end
