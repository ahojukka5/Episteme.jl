@testset "execution contexts survive capsules and integrity writers" begin
    context = ExecutionContext(numerics=(precision="Float64", fast_math=false))
    registry = ExecutionContextRegistry((context,))
    revision = RevisionId(REV_1)
    mesh = _obj(:delone, "mesh", ID_MESH, REV_1; content=CAPSULE_CONTENT_A,
        uuid=UUID_DELONE, provenance=ProvenanceRefs(execution_context=context.id))
    source = ArchiveGraph([mesh]; revisions=[RevisionRecord(revision)])
    schemas = SchemaRegistry([_mesh_def()])
    plan = plan_capsule(source, revision, schemas)
    @test isvalid(plan)
    before = to_namedtuple(source)
    mktempdir() do dir
        path = joinpath(dir, "context-capsule.ah5")
        write_capsule_archive(path, source, plan, schemas;
            source_archive_id="context-source", execution_contexts=registry)
        @test isvalid(inspect_archive(path, CapsuleManifest))
        view = inspect_archive(path, ExecutionContextRegistry)
        @test isvalid(view)
        @test to_namedtuple(view.registry) == to_namedtuple(registry)
        graph = reconstruct_graph(inspect_archive(path, ArchiveEventHistory))
        @test only(graph.objects).provenance.execution_context == context.id
        @test to_namedtuple(source) == before
        missing = joinpath(dir, "missing-capsule.ah5")
        @test_throws ArgumentError write_capsule_archive(missing, source, plan, schemas;
            source_archive_id="context-source", execution_contexts=ExecutionContextRegistry())
        @test !ispath(missing)
        manifest = integrity_manifest(source, revision, schemas)
        for (index, argument) in enumerate((manifest, [manifest]))
            target = joinpath(dir, "integrity-$index.ah5")
            write_archive(target, argument; graph=source, schemas, execution_contexts=registry)
            @test isvalid(inspect_archive(target, RevisionIntegrityManifest))
            @test to_namedtuple(inspect_archive(target, ExecutionContextRegistry).registry) ==
                to_namedtuple(registry)
        end
    end
end

@testset "staged restart and event-only execution references" begin
    context = ExecutionContext(parallelism=(rank_count=2,))
    registry = ExecutionContextRegistry((context,))
    source, _, _, original = _run_history_fixture()
    staged = only(original.staged)
    recorded = StagedObject(staged.object_id; content_id=staged.content_id,
        namespace=staged.namespace, kind=staged.kind, schema=staged.schema,
        origin=staged.origin, activity_id=staged.activity_id, references=staged.references,
        provenance=ProvenanceRefs(execution_context=context.id))
    restart = RestartRequirement(checkpoints=original.restart.checkpoints,
        execution_context=context.id, from_activity_id=original.restart.from_activity_id)
    run = RunRecord(original.id; plan_id=original.plan_id, revision_id=original.revision_id,
        status=original.status, activities=original.activities, staged=[recorded],
        execution_context=context.id, restart)
    graph = ArchiveGraph(source.objects; revisions=source.revisions, heads=source.heads, runs=[run])
    mktempdir() do dir
        path = joinpath(dir, "staged-context.ah5")
        write_run_archive(path, graph; schemas=SchemaRegistry([_mesh_def()]), execution_contexts=registry)
        @test isvalid(inspect_archive(path, ExecutionContextRegistry))
        restored = only(inspect_archive(path, ArchiveRunHistory).runs)
        @test restored.restart.execution_context == context.id
        @test only(restored.staged).provenance.execution_context == context.id
        JLD2.jldopen(path, "r+") do file
            key = Episteme._entry_key(Episteme.AH5_RUN_HISTORY_KEY, 1)
            delete!(file, key)
            file[key] = merge(Episteme._run_record_storage(run),
                (; staged_execution_context=["unrecorded-staged-context"]))
        end
        @test isvalid(inspect_archive(path, ArchiveRunHistory))
        @test !isvalid(inspect_archive(path, ExecutionContextRegistry))

        event_run = RunRecord(RunId("event-only"))
        event = EventRecord(:started, event_run.id; sequence=0, source="test",
            execution_context=context.id)
        events = ArchiveGraph(ArchiveObject[]; runs=[event_run], events=[event])
        @test ArchiveProvenanceSummary(events).execution_contexts == (context.id.value,)
        missing = joinpath(dir, "missing-event.ah5")
        @test_throws ArgumentError write_event_archive(missing, events;
            execution_contexts=ExecutionContextRegistry())
        @test !ispath(missing)
        target = joinpath(dir, "event-context.ah5")
        write_event_archive(target, events; execution_contexts=registry)
        @test isvalid(inspect_archive(target, ExecutionContextRegistry))
    end
end

@testset "domain RNG checkpoint supports declared continuation" begin
    step(state::UInt64) = UInt64(6364136223846793005) * state + UInt64(1)
    states = accumulate((state, _) -> step(state), 1:10; init=UInt64(42))
    mktempdir() do dir
        checkpoint = joinpath(dir, "toy-state.txt")
        write(checkpoint, string(states[5]))
        artifact = ArtifactRef(:file; path=checkpoint)
        identity = capture_external_integrity(ExternalRequirement(ObjectId("toy-rng-state"); artifact))
        context = ExecutionContext(rng=(algorithm="toy-lcg64", version="1",
            state_content=identity.content_id, replay="state"))
        requirement = ExternalRequirement(ObjectId("toy-rng-state");
            content_id=identity.content_id, artifact)
        path = joinpath(dir, "rng.ah5")
        write_archive(path; execution_contexts=ExecutionContextRegistry((context,)), externals=[requirement])
        view = inspect_archive(path, ExecutionContextRegistry)
        @test isvalid(view)
        recorded = only(view.registry.contexts).facts.rng
        external = only(inspect_archive(path).externals)
        @test recorded.state_content == external.content_id.value
        @test isvalid(verify_external(identity; level=:full))
        state = parse(UInt64, read(external.artifact.path, String))
        continued = accumulate((state, _) -> step(state), 1:5; init=state)
        @test continued == states[6:10]
        write(checkpoint, "0")
        @test !isvalid(verify_external(identity; level=:full))
        # Metadata inspection makes no claim that referenced bytes are intact.
        @test isvalid(inspect_archive(path, ExecutionContextRegistry))
    end
end
