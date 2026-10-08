# Run before importing JLD2 so this exercises the consumer's unloaded state.
@testset "AH5 persistence requires explicit activation" begin
    @test Base.get_extension(Episteme, :EpistemeJLD2Ext) === nothing
    @test !any(id -> id.name == "JLD2", keys(Base.loaded_modules))

    mktempdir() do dir
        path = joinpath(dir, "not-created.ah5")
        graph = ArchiveGraph(ArchiveObject[])
        reference = ObjectRef(ObjectId("view"); revision_id=RevisionId("revision"))
        dataset = XdmfDataset("/data/points", reference, ContentId("object");
            content_id=ContentId("array"))
        view = XdmfGrid("unloaded", dataset, dataset; cells=1)
        for operation in (
            () -> write_archive(path),
            () -> inspect_archive(path),
            () -> inspect_xdmf_view(path, view),
            () -> write_xdmf_view(path, "missing.ah5", view),
            () -> is_ah5_archive(path),
            () -> write_archive(path, RevisionIntegrityManifest[]),
            () -> inspect_archive(path, RevisionIntegrityManifest),
            () -> inspect_archive(path, ArchiveStateHistory),
            () -> inspect_archive(path, ArchiveRunHistory),
            () -> inspect_archive(path, ArchiveEventHistory),
            () -> inspect_archive(path, ArchiveDerivedHistory),
            () -> write_state_archive(path, graph),
            () -> write_run_archive(path, graph),
            () -> write_event_archive(path, graph),
            () -> write_derived_archive(path, graph, DerivedArtifactRecord[]),
            () -> write_capsule_archive(path, graph),
            () -> inspect_archive(path, CapsuleManifest),
            () -> verify_capsule(path),
            () -> inspect_archive(path, SoftwareEnvironmentRegistry),
            () -> write_archive(path; software_environments=SoftwareEnvironmentRegistry()),
            () -> inspect_archive(path, ExecutionContextRegistry),
            () -> write_archive(path; execution_contexts=ExecutionContextRegistry()),
            () -> materialize_migration(
                path,
                joinpath(dir, "missing-source.ah5"),
                MigrationRequest[],
                SchemaMigrationRegistry(SchemaMigrationStep[]),
            ),
        )
            err = try
                operation()
                nothing
            catch caught
                caught
            end
            @test err isa ErrorException
            @test occursin("using JLD2", sprint(showerror, err))
            @test !ispath(path)
        end
    end
end
