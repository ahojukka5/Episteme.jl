@testset "AH5 software environments" begin
    environment = SoftwareEnvironment((SoftwareComponent("released", "Released";
        version="1.0.0", source_identity="tree:" * repeat("a", 40),
        dirty=false, dependencies=(), features=()),);
        julia_version="1.12.7", julia_build="recorded-build", features=())
    registry = SoftwareEnvironmentRegistry((environment,))
    mktempdir() do dir
        path = joinpath(dir, "environment.ah5")
        write_archive(path; software_environments=registry)
        view = inspect_archive(path, SoftwareEnvironmentRegistry)
        @test isvalid(view)
        @test view.feature_declared
        @test to_namedtuple(view.registry) == to_namedtuple(registry)
        @test find_software_environment(view.registry, environment.id).julia_build == "recorded-build"
        @test_throws ArgumentError write_archive(path; software_environments=registry)

        old = joinpath(dir, "old.ah5")
        write_archive(old)
        historical = inspect_archive(old, SoftwareEnvironmentRegistry)
        @test isvalid(historical)
        @test !historical.feature_declared
        @test historical.registry === nothing
        @test any(d -> d.code == :software_provenance_unknown, historical.diagnostics)

        collision = joinpath(dir, "collision.ah5")
        @test_throws ArgumentError write_archive(collision; software_environments=registry,
            profile=ArchiveProfile(roots=ArchiveProfileRoots(
                provenance="episteme/software_environments/provenance")))
        @test !ispath(collision)
        missing = joinpath(dir, "missing.ah5")
        @test_throws ArgumentError write_archive(missing;
            profile=ArchiveProfile(features=(Episteme.AH5_V1_FEATURES...,
                Episteme.AH5_SOFTWARE_ENVIRONMENTS_FEATURE)))
        @test !ispath(missing)

        # Forensic readers verify content identity rather than trusting the key.
        JLD2.jldopen(path, "r+") do file
            key = Episteme._entry_key(Episteme.AH5_SOFTWARE_ENVIRONMENTS_KEY, 1) * "/record"
            delete!(file, key)
            file[key] = merge(Episteme._software_environment_storage(environment),
                (; julia_build="altered-build"))
        end
        damaged = inspect_archive(path, SoftwareEnvironmentRegistry)
        @test !isvalid(damaged)
        @test damaged.registry === nothing
        @test any(d -> d.code == :invalid_software_environment_records, damaged.diagnostics)
    end
end

@testset "AH5 shared environments and recorded gaps" begin
    unknown = SoftwareEnvironment((SoftwareComponent("old", "Historical"),))
    empty = SoftwareEnvironment((); features=())
    registry = SoftwareEnvironmentRegistry((unknown, empty))
    runs = [RunRecord(RunId("first"); software_environment=unknown.id),
        RunRecord(RunId("second"); software_environment=unknown.id)]
    graph = ArchiveGraph(ArchiveObject[]; runs)
    mktempdir() do dir
        for writer in (write_state_archive, write_run_archive, write_event_archive)
            path = joinpath(dir, string(writer) * ".ah5")
            writer(path, graph; software_environments=registry)
            view = inspect_archive(path, SoftwareEnvironmentRegistry)
            @test isvalid(view)
            @test to_namedtuple(view.registry) == to_namedtuple(registry)
            @test find_software_environment(view.registry, unknown.id).features === nothing
            @test find_software_environment(view.registry, empty.id).features == ()
            @test inspect_archive(path).provenance.software_environments == (unknown.id.value,)
            if writer !== write_state_archive
                history = inspect_archive(path, ArchiveRunHistory)
                @test isvalid(history)
                restored = reconstruct_graph(history)
                @test length(restored.runs) == 2
                @test all(run -> run.software_environment == unknown.id, restored.runs)
            end
        end
        for writer in (write_state_archive, write_run_archive, write_event_archive)
            missing = joinpath(dir, "missing-" * string(writer) * ".ah5")
            @test_throws ArgumentError writer(missing, graph;
                software_environments=SoftwareEnvironmentRegistry((empty,)))
            @test !ispath(missing)
        end
        path = joinpath(dir, "empty.ah5")
        write_archive(path; software_environments=SoftwareEnvironmentRegistry())
        @test isempty(inspect_archive(path, SoftwareEnvironmentRegistry).registry.environments)
    end
end
