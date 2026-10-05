# Cross-package lifecycle proof. Runs in its own process so Delone's
# readiness methods never enter this suite. Episteme does not depend on Delone.

if VERSION < v"1.11"
    @info "skipping the Delone lifecycle proof; Delone requires Julia 1.11" VERSION
else
    @testset "Delone scientific lifecycle" begin
        project = joinpath(@__DIR__, "scientific_lifecycle")
        script = joinpath(project, "runtests.jl")
        exe = joinpath(Sys.BINDIR, Base.julia_exename())
        cmd = addenv(
            `$exe --startup-file=no -t 4 --project=$project $script`,
            "JULIA_PKG_PRECOMPILE_AUTO" => "0",
        )
        buffer = IOBuffer()
        ok = success(pipeline(cmd; stdout = buffer, stderr = buffer))
        output = String(take!(buffer))
        ok || print(output)
        @test ok
    end
end
