# Optional cross-package proof for the in-memory lifecycle.
# Set EPISTEME_DELONE_ROOT to a Delone checkout. Episteme does not depend
# on Delone, and this file does not load it into the Episteme test process.
# The isolated test environment cannot import stdlibs it does not depend on,
# so the temporary project file is written directly.

function _toml_string(value::AbstractString)
    escaped = replace(replace(value, "\\" => "\\\\"), "\"" => "\\\"")
    return "\"" * escaped * "\""
end

function _write_lifecycle_project(dir, episteme_root, delone_root)
    open(joinpath(dir, "Project.toml"), "w") do io
        println(io, "name = \"EpistemeScientificLifecycle\"")
        println(io, "uuid = \"c31a9e70-6b14-4f0a-9d55-2a7c8e4b1d60\"")
        println(io, "[deps]")
        println(io, "Delone = \"0a3734f8-1dfd-4ffb-90f2-cbaa38dcac37\"")
        println(io, "Episteme = \"7c15cd61-9c6a-4671-bc94-9960963998ac\"")
        println(io, "Pkg = \"44cfe95a-1eb2-52ea-b672-e2afdf69b78f\"")
        println(io, "Test = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"")
        println(io, "[sources]")
        println(io, "Delone = {path = ", _toml_string(abspath(delone_root)), "}")
        println(io, "Episteme = {path = ", _toml_string(abspath(episteme_root)), "}")
    end
    return dir
end

function _run_scientific_lifecycle(delone_root::AbstractString)
    episteme_root = dirname(dirname(pathof(Episteme)))
    dir = mktempdir(; prefix = "episteme-delone-lifecycle-")
    try
        _write_lifecycle_project(dir, episteme_root, delone_root)
        script = joinpath(@__DIR__, "scientific_lifecycle.jl")
        exe = joinpath(Sys.BINDIR, Base.julia_exename())
        log = joinpath(dir, "lifecycle.log")
        # Pkg.test sets JULIA_LOAD_PATH to the parent test project. Drop it
        # so this child resolves the project above, including Pkg.
        child_env = Dict{String,String}(ENV)
        delete!(child_env, "JULIA_LOAD_PATH")
        child_env["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
        child_env["JULIA_PROJECT"] = dir
        cmd = setenv(
            `$exe --startup-file=no --project=$dir $script`,
            child_env,
        )
        ok = success(pipeline(cmd; stdout = log, stderr = log))
        print(read(log, String))
        return ok
    finally
        rm(dir; recursive = true, force = true)
    end
end

let root = strip(get(ENV, "EPISTEME_DELONE_ROOT", ""))
    if isempty(root)
        @info "EPISTEME_DELONE_ROOT is unset; skipping the Delone lifecycle proof"
    else
        @testset "Delone delaunay scientific lifecycle" begin
            @test isdir(root)
            project = read(joinpath(root, "Project.toml"), String)
            @test occursin("0a3734f8-1dfd-4ffb-90f2-cbaa38dcac37", project)
            @test _run_scientific_lifecycle(root)
        end
    end
end
