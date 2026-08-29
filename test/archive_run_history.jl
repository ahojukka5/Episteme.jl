const RUN_CONTENT_INPUT = "sha256:" * repeat("c", 64)
const RUN_CONTENT_OUTPUT = "sha256:" * repeat("d", 64)
const RUN_CONTENT_STAGED = "sha256:" * repeat("e", 64)

function _run_history_fixture()
    r0 = RevisionId(REV_1)
    r1 = RevisionId(REV_2)
    run_id = RunId("run-state-1")
    activity_id = ActivityId("activity-state-1")

    input = _obj(
        :delone,
        "mesh",
        ID_GEOM,
        REV_1;
        content = RUN_CONTENT_INPUT,
        uuid = UUID_DELONE,
    )
    output = _obj(
        :delone,
        "mesh",
        ID_MESH,
        REV_2;
        content = RUN_CONTENT_OUTPUT,
        run = run_id.value,
        uuid = UUID_DELONE,
        references = [ArchiveReference(:input, ObjectId(ID_GEOM); revision_id = r0)],
    )
    activity = ActivityRecord(
        activity_id,
        run_id,
        Symbol("delone/build");
        idempotency_key = "build-state-1",
        used = [ArchiveReference(:input, ObjectId(ID_GEOM); revision_id = r0)],
        generated = [ArchiveReference(:output, ObjectId(ID_MESH); revision_id = r1)],
        reuse = :computed,
    )
    staged = StagedObject(
        ObjectId(ID_MESH);
        content_id = ContentId(RUN_CONTENT_OUTPUT),
        namespace = ArchiveNamespace(:delone; package_uuid = UUID_DELONE, display_name = "Delone.jl"),
        kind = Symbol("delone/mesh"),
        schema = SchemaRef(:delone, "mesh", "1.0.0"),
        origin = :generated,
        activity_id = activity_id,
        references = [ArchiveReference(:input, ObjectId(ID_GEOM); revision_id = r0)],
    )
    restart = RestartRequirement(;
        checkpoints = [CheckpointRef(
            ObjectId(ID_MESH);
            content_id = ContentId(RUN_CONTENT_OUTPUT),
            revision_id = r1,
            kind = :checkpoint,
        )],
        execution_context = ExecutionContextId("ctx-run-1"),
        from_activity_id = activity_id,
    )
    run = RunRecord(
        run_id;
        plan_id = PlanId("plan-state-1"),
        revision_id = r1,
        status = :completed,
        software_environment = SoftwareEnvironmentId("env-run-1"),
        execution_context = ExecutionContextId("ctx-run-1"),
        agent_id = AgentId("agent-run-1"),
        activities = [activity],
        staged = [staged],
        restart = restart,
    )
    graph = ArchiveGraph(
        [input, output];
        heads = [WorkflowHead(WorkflowHeadId("head-run"), :main, r1)],
        revisions = [
            RevisionRecord(r0),
            RevisionRecord(r1; parents = [r0], run_id = run_id, plan_id = PlanId("plan-state-1")),
        ],
        runs = [run],
    )
    return graph, r0, r1, run
end

@testset "AH5 run history restores replay restart and rerun provenance" begin
    mktempdir() do dir
        graph, _, revision_id, original_run = _run_history_fixture()
        schemas = SchemaRegistry([_mesh_def()])
        @test isvalid(validate(graph))

        path = joinpath(dir, "run-history.ah5")
        write_run_archive(path, graph; schemas = schemas)

        core = inspect_archive(path)
        @test core.identified
        @test AH5_STATE_HISTORY_FEATURE in core.profile.features
        @test AH5_RUN_HISTORY_FEATURE in core.profile.features

        view = inspect_archive(path, ArchiveRunHistory)
        @test view.identified
        @test view.feature_declared
        @test isvalid(view)
        @test isvalid(validate(view))
        @test length(view.runs) == 1

        restored_run = only(view.runs)
        @test restored_run.id == original_run.id
        @test restored_run.plan_id == original_run.plan_id
        @test restored_run.revision_id == original_run.revision_id
        @test restored_run.software_environment == original_run.software_environment
        @test restored_run.execution_context == original_run.execution_context
        @test restored_run.agent_id == original_run.agent_id
        @test length(restored_run.activities) == 1
        @test restored_run.activities[1].id == original_run.activities[1].id
        @test restored_run.activities[1].used == original_run.activities[1].used
        @test restored_run.activities[1].generated == original_run.activities[1].generated
        @test length(restored_run.staged) == 1
        @test restored_run.staged[1].object_id == ObjectId(ID_MESH)
        @test restored_run.staged[1].content_id == ContentId(RUN_CONTENT_OUTPUT)
        @test restored_run.restart !== nothing
        @test restored_run.restart.checkpoints == original_run.restart.checkpoints

        manifest = inspect(view, revision_id)
        @test manifest.run !== nothing
        @test manifest.run.id == original_run.id
        @test isready(readiness(manifest, PipelineTarget(:inspect)))
        @test isready(readiness(manifest, PipelineTarget(:replay)))
        @test isready(readiness(manifest, PipelineTarget(:restart)))
        @test isready(readiness(manifest, PipelineTarget(:rerun)))

        reconstructed = reconstruct_graph(view)
        @test length(reconstructed.events) == 0
        @test length(reconstructed.writes) == 0
        @test length(reconstructed.log_streams) == 0
        @test isvalid(validate(reconstructed))
    end
end

@testset "incomplete runs preserve run-local staged generated references" begin
    mktempdir() do dir
        r0 = RevisionId(REV_1)
        input = _obj(
            :delone,
            "mesh",
            ID_GEOM,
            REV_1;
            content = RUN_CONTENT_INPUT,
            uuid = UUID_DELONE,
        )
        parent = RunRecord(RunId("run-parent"); status = :failed)
        child_id = RunId("run-child")
        activity_id = ActivityId("activity-child")
        activity = ActivityRecord(
            activity_id,
            child_id,
            Symbol("delone/build");
            used = [ArchiveReference(:input, ObjectId(ID_GEOM); revision_id = r0)],
            generated = [ArchiveReference(:candidate, ObjectId(ID_POST))],
        )
        staged = StagedObject(
            ObjectId(ID_POST);
            content_id = ContentId(RUN_CONTENT_STAGED),
            namespace = ArchiveNamespace(:delone; package_uuid = UUID_DELONE, display_name = "Delone.jl"),
            kind = Symbol("delone/mesh"),
            schema = SchemaRef(:delone, "mesh", "1.0.0"),
            origin = :generated,
            activity_id = activity_id,
            references = [ArchiveReference(:input, ObjectId(ID_GEOM); revision_id = r0)],
        )
        child = RunRecord(
            child_id;
            parent_run_id = parent.id,
            status = :failed,
            software_environment = SoftwareEnvironmentId("env-child"),
            activities = [activity],
            staged = [staged],
        )
        graph = ArchiveGraph(
            [input];
            revisions = [RevisionRecord(r0)],
            runs = [parent, child],
        )
        schemas = SchemaRegistry([_mesh_def()])
        @test isvalid(validate(graph))

        path = joinpath(dir, "incomplete.ah5")
        write_run_archive(path, graph; schemas = schemas)
        view = inspect_archive(path, ArchiveRunHistory)
        @test isvalid(view)
        @test length(view.runs) == 2
        restored = only(run for run in view.runs if run.id == child_id)
        @test restored.parent_run_id == parent.id
        @test restored.revision_id === nothing
        @test restored.status === :failed
        @test length(restored.staged) == 1
        @test restored.activities[1].generated[1].target.object_id == ObjectId(ID_POST)
        @test restored.staged[1].object_id == ObjectId(ID_POST)
    end
end

@testset "crafted run-history parent links fail closed" begin
    mktempdir() do dir
        graph, _, _, _ = _run_history_fixture()
        path = joinpath(dir, "corrupt-parent.ah5")
        write_run_archive(path, graph; schemas = SchemaRegistry([_mesh_def()]))

        key = "$(AH5_RUN_HISTORY_KEY)/1"
        JLD2.jldopen(path, "r+") do file
            raw = file[key]
            file[key] = merge(raw, (; parent_run_id = "missing-parent-run"))
        end

        view = inspect_archive(path, ArchiveRunHistory)
        @test view.identified
        @test view.feature_declared
        @test !isvalid(view)
        @test view.state === nothing
        @test isempty(view.runs)
        @test any(d -> d.code === :missing_parent_run, view.diagnostics)
        @test_throws ArgumentError reconstruct_graph(view)
    end
end

@testset "old state-history archives remain valid without run history" begin
    mktempdir() do dir
        r1 = RevisionId(REV_1)
        object = _obj(
            :delone,
            "mesh",
            ID_MESH,
            REV_1;
            content = RUN_CONTENT_OUTPUT,
            uuid = UUID_DELONE,
        )
        graph = ArchiveGraph([object]; revisions = [RevisionRecord(r1)])
        path = joinpath(dir, "state-only.ah5")
        write_state_archive(path, graph; schemas = SchemaRegistry([_mesh_def()]))

        view = inspect_archive(path, ArchiveRunHistory)
        @test view.identified
        @test !view.feature_declared
        @test isvalid(view)
        @test view.state !== nothing
        @test isempty(view.runs)
    end
end
