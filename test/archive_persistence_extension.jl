# The JLD2 weakdep boundary. This suite runs with JLD2 present, so the
# extension must be loaded and the archive API must behave exactly as it did
# when JLD2 was a hard dependency. The fail-closed owner stubs are still
# reachable here through the deliberately broad fallback signature, which is
# how this file proves they throw instead of silently doing nothing.

@testset "JLD2 persistence extension" begin
    @testset "extension is loaded when JLD2 is available" begin
        @test Base.get_extension(Episteme, :EpistemeJLD2Ext) !== nothing
    end

    @testset "owner stubs fail closed with an actionable message" begin
        err = Episteme._missing_jld2_error("write_archive")
        @test err isa ErrorException
        @test occursin("write_archive", err.msg)
        @test occursin("JLD2", err.msg)
        @test occursin("using JLD2", err.msg)
        @test occursin("EpistemeJLD2Ext", err.msg)

        # No extension method matches these argument lists, so the broad owner
        # fallback answers. A silent no-op would be worse than a hard
        # dependency: an archive that was never written must not look written.
        for f in (
            Episteme.write_archive,
            Episteme.inspect_archive,
            Episteme.write_state_archive,
            Episteme.write_run_archive,
            Episteme.write_event_archive,
        )
            thrown = try
                f(:no_such_archive_argument, 0x1)
                nothing
            catch caught
                caught
            end
            @test thrown isa ErrorException
            @test occursin("using JLD2", thrown.msg)
        end
    end

    @testset "extension methods are more specific than the stubs" begin
        # Dispatch, not overwriting: the owner keeps its broad fallback and the
        # extension adds narrower methods, so `using JLD2` never redefines an
        # owner method.
        for sig in (
            Tuple{AbstractString},
            Tuple{AbstractString,Type{ArchiveStateHistory}},
            Tuple{AbstractString,Type{ArchiveRunHistory}},
            Tuple{AbstractString,Type{ArchiveEventHistory}},
            Tuple{AbstractString,Type{RevisionIntegrityManifest}},
        )
            method = which(inspect_archive, sig)
            @test parentmodule(method) === Base.get_extension(Episteme, :EpistemeJLD2Ext)
        end
        @test parentmodule(which(write_archive, Tuple{AbstractString})) ===
            Base.get_extension(Episteme, :EpistemeJLD2Ext)
        @test parentmodule(which(write_state_archive, Tuple{AbstractString,ArchiveGraph})) ===
            Base.get_extension(Episteme, :EpistemeJLD2Ext)
        @test parentmodule(which(write_run_archive, Tuple{AbstractString,ArchiveGraph})) ===
            Base.get_extension(Episteme, :EpistemeJLD2Ext)
        @test parentmodule(which(write_event_archive, Tuple{AbstractString,ArchiveGraph})) ===
            Base.get_extension(Episteme, :EpistemeJLD2Ext)
        # The external-aware String specialization stays in the owner package.
        @test parentmodule(which(write_archive, Tuple{String})) === Episteme
    end

    @testset "documentation survives without the extension" begin
        # The docstrings live on the owner stubs, not on the extension methods,
        # so `?write_archive` still answers in a stdlib-only install. Read the
        # module's own doc metadata, which is the same on every supported Julia:
        # `Base.Docs.doc` itself only gains methods once the REPL stdlib is
        # loaded, and `Docs.hasdoc` is newer than this package's julia compat.
        registry = Base.Docs.meta(Episteme)
        @test registry isa AbstractDict
        for name in (
            :write_archive,
            :inspect_archive,
            :write_state_archive,
            :write_run_archive,
            :write_event_archive,
        )
            binding = Base.Docs.Binding(Episteme, name)
            @test haskey(registry, binding)
            text = join(
                (string(entry.text...) for entry in values(registry[binding].docs)),
                "\n",
            )
            @test occursin("Requires JLD2", text)
        end
    end

    @testset "round trip is unchanged with JLD2 loaded" begin
        mktempdir() do dir
            path = joinpath(dir, "extension.ah5")
            @test write_archive(path) == path
            @test isfile(path)
            inspection = inspect_archive(path)
            @test inspection.identified
            @test isvalid(validate(inspection))
            @test is_ah5_archive(path)
        end
    end
end
