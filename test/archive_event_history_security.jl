@testset "event payload empty collections survive plain storage" begin
    mktempdir() do dir
        run = RunRecord(RunId("empty-payload"))
        for (index, payload) in enumerate(((;), (nested=(;), values=(), data=Int[])))
            event = EventRecord(:empty, run.id; sequence=0, source="test", payload)
            graph = ArchiveGraph(ArchiveObject[]; runs=[run], events=[event])
            path = joinpath(dir, "$index.ah5")
            write_event_archive(path, graph)
            view = inspect_archive(path, ArchiveEventHistory)
            @test isvalid(view)
            @test canonical_content_id(only(view.events).payload) == canonical_content_id(payload)
        end
    end
end

@testset "GitHub credential shapes cannot enter event archives" begin
    # Synthetic fixtures only; never use live credentials in regression tests.
    candidates = [prefix * repeat("A", 36) for prefix in
        ("ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_")]
    push!(candidates, "ghs_12345_" * repeat("A", 12) * "." * repeat("B", 12))
    for candidate in candidates
        graph, _, _ = _event_history_fixture()
        run = only(graph.runs)
        event = EventRecord(:credential_probe, run.id;
            sequence = 1, source = "test", message = "received " * candidate)
        @test !isvalid(validate(event))
        @test !occursin(candidate, repr(validate(event)))
        nested = EventRecord(:credential_probe, run.id;
            sequence = 1, source = "test",
            payload = (details = (values = [candidate],),))
        invalid_graph = ArchiveGraph(graph.objects;
            heads = graph.heads, revisions = graph.revisions, runs = graph.runs,
            events = [nested])
        mktempdir() do dir
            path = joinpath(dir, "credential.ah5")
            @test_throws ArgumentError write_event_archive(path, invalid_graph;
                schemas = SchemaRegistry([_mesh_def()]))
            @test !ispath(path)
        end
    end
    for message in ("GitHub uses ghp_ and github_pat_ prefixes", "commit " * repeat("a", 40))
        event = EventRecord(:note, RunId("run"); sequence = 1,
            source = "test", message = message)
        @test isvalid(validate(event))
    end
end

@testset "event history rejects credential-like writer tokens" begin
    mktempdir() do dir
        graph, _, _ = _event_history_fixture()
        run = only(graph.runs)
        secret_write = WriteTransaction(;
            scope = :run,
            phase = :committed,
            sequence = 1,
            run_id = run.id,
            writer_token = "Bearer " * repeat("A", 32),
        )
        secret_graph = ArchiveGraph(
            graph.objects;
            heads = graph.heads,
            revisions = graph.revisions,
            runs = graph.runs,
            events = graph.events,
            writes = [secret_write],
            log_streams = graph.log_streams,
        )
        path = joinpath(dir, "writer-secret.ah5")
        @test_throws ArgumentError write_event_archive(
            path,
            secret_graph;
            schemas = SchemaRegistry([_mesh_def()]),
        )
        @test !ispath(path)
    end
end

@testset "event object refs remain archived-state references" begin
    mktempdir() do dir
        graph, _, _ = _event_history_fixture()
        run = only(graph.runs)
        external_id = ObjectId("external-event-only")
        event = EventRecord(
            :external_ref,
            run.id;
            sequence = 1,
            source = "solver",
            object_refs = [ObjectRef(external_id)],
        )
        direct_external = ExternalRequirement(
            external_id;
            content_id = ContentId("sha256:" * repeat("1", 64)),
            artifact = ArtifactRef(:file; path = "external.bin"),
        )
        invalid_graph = ArchiveGraph(
            graph.objects;
            heads = graph.heads,
            revisions = graph.revisions,
            runs = graph.runs,
            events = [event],
        )
        path = joinpath(dir, "direct-external-event-ref.ah5")
        @test_throws ArgumentError write_event_archive(
            path,
            invalid_graph;
            schemas = SchemaRegistry([_mesh_def()]),
            externals = [direct_external],
        )
        @test !ispath(path)
    end
end

@testset "missing event-history feature cannot hide summarized provenance" begin
    mktempdir() do dir
        graph, _, _ = _event_history_fixture()
        path = joinpath(dir, "run-layer-dropped-events.ah5")

        # The lower-layer writer can encode the core counts while intentionally
        # omitting #85 records. The #85 forensic reader must surface that loss.
        write_run_archive(path, graph; schemas = SchemaRegistry([_mesh_def()]))
        core = inspect_archive(path)
        @test core.history.events == length(graph.events)
        @test core.history.writes == length(graph.writes)
        @test core.history.log_streams == length(graph.log_streams)
        @test AH5_EVENT_HISTORY_FEATURE ∉ core.profile.features

        view = inspect_archive(path, ArchiveEventHistory)
        @test view.identified
        @test !view.feature_declared
        @test !isvalid(view)
        @test view.state === nothing
        @test isempty(view.runs)
        @test any(d -> d.code === :event_history_records_missing, view.diagnostics)
        @test_throws ArgumentError reconstruct_graph(view)
    end
end
