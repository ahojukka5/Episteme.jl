# Run before importing JLD2 so this exercises the consumer's unloaded state.
@testset "AH5 persistence requires explicit activation" begin
    @test Base.get_extension(Episteme, :EpistemeJLD2Ext) === nothing
    @test !any(id -> id.name == "JLD2", keys(Base.loaded_modules))

    mktempdir() do dir
        path = joinpath(dir, "not-created.ah5")
        graph = ArchiveGraph(ArchiveObject[])
        for operation in (
            () -> write_archive(path),
            () -> inspect_archive(path),
            () -> is_ah5_archive(path),
            () -> write_archive(path, RevisionIntegrityManifest[]),
            () -> inspect_archive(path, RevisionIntegrityManifest),
            () -> inspect_archive(path, ArchiveStateHistory),
            () -> inspect_archive(path, ArchiveRunHistory),
            () -> inspect_archive(path, ArchiveEventHistory),
            () -> write_state_archive(path, graph),
            () -> write_run_archive(path, graph),
            () -> write_event_archive(path, graph),
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
