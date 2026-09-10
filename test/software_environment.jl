@testset "immutable software environment facts" begin
    dependency = SoftwareComponent("dep", "Dependency"; version="2.0.0",
        source_identity="git-tree-sha1:" * repeat("a", 40), dirty=false,
        dependencies=(), features=())
    function application(; source="git:" * repeat("b", 40), dirty=false, features=("MPIExt",))
        SoftwareComponent("app", "Application";
            uuid="7c15cd61-9c6a-4671-bc94-9960963998ac", version="1.0.0",
            source_identity=source, dirty, dependencies=["dep", "dep"], features)
    end
    facts = [application(), dependency]
    environment = SoftwareEnvironment(facts; julia_version="1.12.7", julia_build="build-123", features=())
    reordered = SoftwareEnvironment(reverse(facts); julia_version="1.12.7", julia_build="build-123", features=[])
    @test environment.id == reordered.id
    @test to_namedtuple(environment) == to_namedtuple(reordered)
    empty!(facts)
    @test length(environment.components) == 2
    @test environment.components[1].dependencies == ("dep",)
    @test isempty(validate(environment).diagnostics)
    for changed in (application(source="git:" * repeat("c", 40)),
                    application(dirty=true), application(features=()))
        other = SoftwareEnvironment((changed, dependency); julia_version="1.12.7",
            julia_build="build-123", features=())
        @test other.id != environment.id
    end
    modified = SoftwareEnvironment((application(dirty=true), dependency))
    @test any(d -> d.code == :modified_software_source, validate(modified).diagnostics)
    released = SoftwareComponent("release", "Released"; version="3.0.0")
    historical = SoftwareEnvironment((released,))
    @test historical.julia_version === nothing
    @test historical.components[1].repository === nothing
    @test isvalid(validate(historical))
    @test any(d -> d.code == :software_provenance_unknown, validate(historical).diagnostics)
    @test historical.id != SoftwareEnvironment((released,); features=()).id
    @test_throws ArgumentError SoftwareEnvironment((application(),))
    @test_throws ArgumentError SoftwareEnvironment((dependency, dependency))
    @test_throws ArgumentError SoftwareComponent("", "Invalid")
    first_run = RunRecord(RunId("first"); software_environment=environment.id)
    second_run = RunRecord(RunId("second"); software_environment=environment.id)
    @test first_run.software_environment == second_run.software_environment == environment.id
end

@testset "portable software environment registry" begin
    component = SoftwareComponent("library", "Released library"; version="1.0.0",
        source_identity="git-tree-sha1:" * repeat("d", 40), dirty=false,
        dependencies=(), features=())
    first = SoftwareEnvironment((component,); julia_version="1.12.7")
    second = SoftwareEnvironment((component,); julia_version="1.11.9")
    records = [second, first, first]
    registry = SoftwareEnvironmentRegistry(records)
    empty!(records)
    @test length(registry.environments) == 2
    @test find_software_environment(registry, first.id) === first
    @test find_software_environment(registry, SoftwareEnvironmentId("missing")) === nothing
    @test to_namedtuple(registry) == to_namedtuple(SoftwareEnvironmentRegistry((first, second)))
    restored = from_namedtuple(SoftwareEnvironmentRegistry, to_namedtuple(registry))
    @test to_namedtuple(restored) == to_namedtuple(registry)
    @test find_software_environment(restored, first.id).components[1].repository === nothing
    @test isvalid(validate(restored))
    @test !isempty(report(restored).diagnostics)
    @test isempty(SoftwareEnvironmentRegistry().environments)
    portable = to_namedtuple(first)
    @test_throws ArgumentError from_namedtuple(SoftwareEnvironment,
        merge(portable, (; julia_version="1.13.0")))
    @test_throws ArgumentError from_namedtuple(SoftwareEnvironment,
        merge(portable, (; id=second.id.value)))
    @test_throws ArgumentError from_namedtuple(SoftwareEnvironment,
        merge(portable, (; format="episteme-software-environment-v2")))
    altered = merge(portable.components[1], (; dirty=true))
    @test_throws ArgumentError from_namedtuple(SoftwareEnvironment,
        merge(portable, (; components=(altered,))))
end
