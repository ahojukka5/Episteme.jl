@testset "staged software provenance and integrity writer" begin
    environment = SoftwareEnvironment((SoftwareComponent("backend", "Backend";
        version="2.0.0", source_identity="build:backend-2"),))
    registry = SoftwareEnvironmentRegistry((environment,))
    mktempdir() do dir
        source, _, revision, original = _run_history_fixture()
        staged = only(original.staged)
        recorded = StagedObject(staged.object_id; content_id=staged.content_id,
            namespace=staged.namespace, kind=staged.kind, schema=staged.schema,
            origin=staged.origin, activity_id=staged.activity_id,
            references=staged.references,
            provenance=ProvenanceRefs(software_environment=environment.id))
        run = RunRecord(original.id; plan_id=original.plan_id, revision_id=original.revision_id,
            status=original.status, software_environment=environment.id,
            execution_context=original.execution_context, agent_id=original.agent_id,
            activities=original.activities, staged=[recorded], restart=original.restart)
        graph = ArchiveGraph(source.objects; revisions=source.revisions,
            heads=source.heads, runs=[run])
        schemas = SchemaRegistry([_mesh_def()])
        path = joinpath(dir, "staged.ah5")
        write_run_archive(path, graph; schemas, software_environments=registry)
        @test isvalid(inspect_archive(path, SoftwareEnvironmentRegistry))
        history = inspect_archive(path, ArchiveRunHistory)
        @test only(only(history.runs).staged).provenance.software_environment == environment.id
        JLD2.jldopen(path, "r+") do file
            key = Episteme._entry_key(Episteme.AH5_RUN_HISTORY_KEY, 1)
            delete!(file, key)
            file[key] = merge(Episteme._run_record_storage(run),
                (; staged_software_environment=["missing-staged-environment"]))
        end
        @test isvalid(inspect_archive(path, ArchiveRunHistory))
        @test !isvalid(inspect_archive(path, SoftwareEnvironmentRegistry))

        manifest = integrity_manifest(graph, revision, schemas)
        @test isvalid(manifest)
        for (index, argument) in enumerate((manifest, [manifest]))
            target = joinpath(dir, "integrity-$index.ah5")
            write_archive(target, argument; graph, schemas, software_environments=registry)
            @test isvalid(inspect_archive(target, RevisionIntegrityManifest))
            @test to_namedtuple(inspect_archive(target, SoftwareEnvironmentRegistry).registry) ==
                to_namedtuple(registry)
        end
    end
end
