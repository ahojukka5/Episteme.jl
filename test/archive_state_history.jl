const STATE_CONTENT_A = "sha256:" * repeat("a", 64)
const STATE_CONTENT_B = "sha256:" * repeat("b", 64)

function _state_object_signature(object::ArchiveObject)
    return (
        object.object_id.value,
        object.revision_id.value,
        object.content_id === nothing ? nothing : object.content_id.value,
        object.run_id === nothing ? nothing : object.run_id.value,
        object.namespace.id,
        object.namespace.package_uuid,
        object.kind,
        object.schema,
        object.provenance.software_environment === nothing ? nothing :
            object.provenance.software_environment.value,
        object.provenance.execution_context === nothing ? nothing :
            object.provenance.execution_context.value,
        Tuple((ref.name, ref.target.object_id.value,
            ref.target.revision_id === nothing ? nothing : ref.target.revision_id.value)
            for ref in ordered_references(object)),
    )
end

@testset "AH5 state history round-trips authoritative revision state" begin
    mktempdir() do dir
        r0 = RevisionId(REV_1)
        r1 = RevisionId(REV_2)
        geom = _obj(
            :delone,
            "mesh",
            ID_GEOM,
            REV_1;
            content = STATE_CONTENT_A,
            uuid = UUID_DELONE,
        )
        mesh = _obj(
            :delone,
            "mesh",
            ID_MESH,
            REV_2;
            content = STATE_CONTENT_B,
            uuid = UUID_DELONE,
            provenance = ProvenanceRefs(;
                software_environment = SoftwareEnvironmentId("env-state"),
                execution_context = ExecutionContextId("ctx-state"),
            ),
            references = [
                ArchiveReference(:geometry, ObjectId(ID_GEOM); revision_id = r0),
            ],
        )
        graph = ArchiveGraph(
            [geom, mesh];
            heads = [WorkflowHead(WorkflowHeadId("head-main"), :main, r1)],
            revisions = [
                RevisionRecord(r0),
                RevisionRecord(r1; parents = [r0], plan_id = PlanId("plan-state")),
            ],
        )
        schemas = SchemaRegistry([_mesh_def()])
        before_objects = copy(graph.objects)
        before_revisions = copy(graph.revisions)

        path = joinpath(dir, "state.ah5")
        write_state_archive(path, graph; schemas = schemas)

        core = inspect_archive(path)
        @test core.identified
        @test AH5_STATE_HISTORY_FEATURE in core.profile.features

        view = inspect_archive(path, ArchiveStateHistory)
        @test view.identified
        @test view.feature_declared
        @test isvalid(view)
        @test isvalid(validate(view))
        @test view.state !== nothing
        @test length(view.state.objects) == 2
        @test length(view.state.revisions) == 2
        @test length(view.state.heads) == 1

        original = inspect(graph, r1)
        reopened = inspect(view, r1)
        @test reopened.run === nothing
        @test reopened.plan_id == PlanId("plan-state")
        @test Set(_state_object_signature(entry.object) for entry in original.entries
            if entry.object !== nothing) ==
            Set(_state_object_signature(entry.object) for entry in reopened.entries
                if entry.object !== nothing)
        @test [head.name for head in reopened.heads] == [:main]
        @test isempty(reopened.diagnostics)

        @test graph.objects == before_objects
        @test graph.revisions == before_revisions
    end
end

@testset "old AH5 archives remain valid without state-history records" begin
    mktempdir() do dir
        path = joinpath(dir, "old.ah5")
        write_archive(path)
        view = inspect_archive(path, ArchiveStateHistory)
        @test view.identified
        @test !view.feature_declared
        @test isvalid(view)
        @test view.state === nothing
        @test_throws ArgumentError inspect(view, RevisionId(REV_1))
    end
end

@testset "state-history writer refuses invalid graph state before publication" begin
    mktempdir() do dir
        r1 = RevisionId(REV_1)
        dangling = _obj(
            :delone,
            "mesh",
            ID_MESH,
            REV_1;
            content = STATE_CONTENT_A,
            uuid = UUID_DELONE,
            references = [
                ArchiveReference(:missing, ObjectId(ID_GEOM); revision_id = r1),
            ],
        )
        graph = ArchiveGraph([dangling]; revisions = [RevisionRecord(r1)])
        path = joinpath(dir, "invalid.ah5")
        @test_throws ArgumentError write_state_archive(path, graph)
        @test !ispath(path)
    end
end

@testset "crafted dangling state records fail closed" begin
    mktempdir() do dir
        r1 = RevisionId(REV_1)
        mesh = _obj(
            :delone,
            "mesh",
            ID_MESH,
            REV_1;
            content = STATE_CONTENT_A,
            uuid = UUID_DELONE,
        )
        graph = ArchiveGraph(
            [mesh];
            heads = [WorkflowHead(WorkflowHeadId("head-main"), :main, r1)],
            revisions = [RevisionRecord(r1)],
        )
        path = joinpath(dir, "crafted.ah5")
        write_state_archive(path, graph)

        key = "$(AH5_STATE_HISTORY_KEY)/heads/1"
        JLD2.jldopen(path, "r+") do file
            raw = file[key]
            file[key] = merge(raw, (; revision_id = "missing-revision"))
        end

        view = inspect_archive(path, ArchiveStateHistory)
        @test view.identified
        @test view.feature_declared
        @test !isvalid(view)
        @test view.state === nothing
        @test any(d -> d.code === :dangling_head, view.diagnostics)
        @test_throws ArgumentError inspect(view, r1)
    end
end

@testset "declared state-history feature without records is corrupt" begin
    mktempdir() do dir
        path = joinpath(dir, "declared-only.ah5")
        write_archive(
            path;
            profile = ArchiveProfile(; features = (AH5_STATE_HISTORY_FEATURE,)),
        )
        view = inspect_archive(path, ArchiveStateHistory)
        @test view.identified
        @test view.feature_declared
        @test !isvalid(view)
        @test view.state === nothing
        @test any(d -> d.code === :corrupt_state_history, view.diagnostics)
    end
end

include("archive_state_history_identity.jl")
