@testset "AH5 execution records preserve explicit unknowns" begin
    contexts = (ExecutionContext(), ExecutionContext(devices=(), ranks=(), features=()),
        ExecutionContext(hardware=(cpu_architecture="x86_64",),
            rng=(algorithm="toy", version="1", seed=42, replay="seed")))
    registry = ExecutionContextRegistry(contexts)
    mktempdir() do dir
        path = joinpath(dir, "contexts.ah5")
        write_archive(path; execution_contexts=registry)
        view = inspect_archive(path, ExecutionContextRegistry)
        @test isvalid(view)
        @test view.feature_declared
        @test to_namedtuple(view.registry) == to_namedtuple(registry)
        @test to_namedtuple(view).valid
        @test isvalid(report(view))
        @test length(report(view).metadata.contexts) == 3
        @test any(summary -> summary.rng_replay == "seed", report(view).metadata.contexts)
        old = joinpath(dir, "historical.ah5")
        write_archive(old)
        historical = inspect_archive(old, ExecutionContextRegistry)
        @test isvalid(historical)
        @test historical.registry === nothing
        @test any(d -> d.code == :execution_provenance_unknown, historical.diagnostics)
        for (name, kwargs) in (
            ("unbound", (; profile=ArchiveProfile(features=(Episteme.AH5_V1_FEATURES...,
                Episteme.AH5_EXECUTION_CONTEXTS_FEATURE)))),
            ("collision", (; execution_contexts=registry,
                profile=ArchiveProfile(roots=ArchiveProfileRoots(
                    provenance="episteme/execution_contexts/provenance")))))
            rejected = joinpath(dir, name * ".ah5")
            @test_throws ArgumentError write_archive(rejected; kwargs...)
            @test !ispath(rejected)
        end
        # Alter one recorded id; the reader must rederive identity from facts.
        JLD2.jldopen(path, "r+") do file
            root = Episteme._entry_key(Episteme.AH5_EXECUTION_CONTEXTS_KEY, 1)
            names = file[root * "/names"]
            key = Episteme._entry_key(root, findfirst(==("id"), names)) * "/value"
            delete!(file, key)
            file[key] = "execution:forged"
        end
        corrupted = inspect_archive(path, ExecutionContextRegistry)
        @test !isvalid(corrupted)
        @test corrupted.registry === nothing
    end
end

@testset "context registries cover authoritative references" begin
    context = ExecutionContext(numerics=(precision="Float64",))
    registry = ExecutionContextRegistry((context,))
    run = RunRecord(RunId("context-run"); execution_context=context.id)
    event = EventRecord(:started, run.id; sequence=0, source="test",
        execution_context=context.id)
    graph = ArchiveGraph(ArchiveObject[]; runs=[run], events=[event])
    mktempdir() do dir
        missing = joinpath(dir, "missing.ah5")
        @test_throws ArgumentError write_archive(missing; graph,
            execution_contexts=ExecutionContextRegistry())
        @test !ispath(missing)
        path = joinpath(dir, "events.ah5")
        write_event_archive(path, graph; execution_contexts=registry)
        view = inspect_archive(path, ExecutionContextRegistry)
        @test isvalid(view)
        @test find_execution_context(view.registry, context.id).facts.numerics.precision == "Float64"
        # Removing summary references cannot hide authoritative run/event refs.
        JLD2.jldopen(path, "r+") do file
            provenance = file[Episteme.AH5_PROVENANCE_KEY]
            delete!(file, Episteme.AH5_PROVENANCE_KEY)
            file[Episteme.AH5_PROVENANCE_KEY] = merge(provenance, (; execution_contexts=String[]))
            key = Episteme._count_key(Episteme.AH5_EXECUTION_CONTEXTS_KEY)
            delete!(file, key)
            file[key] = 0
        end
        @test !isvalid(inspect_archive(path, ExecutionContextRegistry))
    end
end
