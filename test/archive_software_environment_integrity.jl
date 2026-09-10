@testset "authoritative software references and capsule preservation" begin
    environment = SoftwareEnvironment((SoftwareComponent("app", "Application";
        version="1.0.0", source_identity="commit:" * repeat("b", 40)),))
    registry = SoftwareEnvironmentRegistry((environment,))
    mktempdir() do dir
        run = RunRecord(RunId("recorded-run"); software_environment=environment.id)
        path = joinpath(dir, "tampered-run.ah5")
        write_run_archive(path, ArchiveGraph(ArchiveObject[]; runs=[run]);
            software_environments=registry)
        JLD2.jldopen(path, "r+") do file
            key = Episteme._entry_key(Episteme.AH5_RUN_HISTORY_KEY, 1)
            delete!(file, key)
            file[key] = merge(Episteme._run_record_storage(run),
                (; software_environment="unrecorded-environment"))
        end
        # The summary still lists the original, resolvable environment.
        @test inspect_archive(path).provenance.software_environments == (environment.id.value,)
        @test isvalid(inspect_archive(path, ArchiveRunHistory))
        @test !isvalid(inspect_archive(path, SoftwareEnvironmentRegistry))

        revision = RevisionId(REV_1)
        mesh = _obj(:delone, "mesh", ID_MESH, REV_1;
            content=CAPSULE_CONTENT_A, uuid=UUID_DELONE,
            provenance=ProvenanceRefs(software_environment=environment.id))
        source = ArchiveGraph([mesh]; revisions=[RevisionRecord(revision)])
        schemas = SchemaRegistry([_mesh_def()])
        plan = plan_capsule(source, revision, schemas)
        @test isvalid(plan)
        capsule = joinpath(dir, "capsule.ah5")
        write_capsule_archive(capsule, source, plan, schemas;
            source_archive_id="environment-source", software_environments=registry)
        @test isvalid(inspect_archive(capsule, CapsuleManifest))
        view = inspect_archive(capsule, SoftwareEnvironmentRegistry)
        @test isvalid(view)
        @test to_namedtuple(view.registry) == to_namedtuple(registry)
        restored = reconstruct_graph(inspect_archive(capsule, ArchiveEventHistory))
        @test only(restored.objects).provenance.software_environment == environment.id
        missing = joinpath(dir, "missing-capsule.ah5")
        @test_throws ArgumentError write_capsule_archive(missing, source, plan, schemas;
            source_archive_id="environment-source", software_environments=SoftwareEnvironmentRegistry())
        @test !ispath(missing)
    end
end
