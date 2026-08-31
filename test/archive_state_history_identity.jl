@testset "forensic state history rejects forged package identity" begin
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
        graph = ArchiveGraph([mesh]; revisions = [RevisionRecord(r1)])
        schemas = SchemaRegistry([_mesh_def()])
        path = joinpath(dir, "forged-uuid.ah5")
        write_state_archive(path, graph; schemas = schemas)

        key = "$(AH5_STATE_HISTORY_KEY)/objects/1"
        JLD2.jldopen(path, "r+") do file
            raw = file[key]
            file[key] = merge(raw, (; package_uuid = ""))
        end

        view = inspect_archive(path, ArchiveStateHistory)
        @test view.identified
        @test view.feature_declared
        @test !isvalid(view)
        @test view.state === nothing
        @test any(d -> d.code === :namespace_identity_missing, view.diagnostics)
        @test_throws ArgumentError inspect(view, r1)
    end
end

@testset "forensic state history rejects reserved namespace impersonation" begin
    mktempdir() do dir
        r1 = RevisionId(REV_1)
        object = ArchiveObject(
            ObjectId(ID_MESH),
            r1;
            content_id = ContentId(STATE_CONTENT_A),
            namespace = episteme_namespace(),
            kind = Symbol("episteme/state"),
            schema = SchemaRef(:episteme, "state", "1.0.0"),
        )
        graph = ArchiveGraph([object]; revisions = [RevisionRecord(r1)])
        path = joinpath(dir, "reserved.ah5")
        write_state_archive(path, graph)

        key = "$(AH5_STATE_HISTORY_KEY)/objects/1"
        JLD2.jldopen(path, "r+") do file
            raw = file[key]
            file[key] = merge(raw, (; package_uuid = "00000000-0000-0000-0000-000000000000"))
        end

        view = inspect_archive(path, ArchiveStateHistory)
        @test !isvalid(view)
        @test view.state === nothing
        @test any(d -> d.code === :reserved_namespace_claimed ||
            d.code === :namespace_identity_conflict, view.diagnostics)
    end
end

include("archive_run_history.jl")
include("archive_event_history.jl")
include("archive_event_history_security.jl")
