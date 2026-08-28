@testset "AH5 inspectable roots stay in a non-overlapping Episteme subtree" begin
    mktempdir() do dir
        valid = ArchiveProfile(;
            roots = ArchiveProfileRoots(; schemas = "episteme/schema_registry_v2"),
        )
        @test isvalid(validate(valid))

        profile_child = ArchiveProfile(;
            roots = ArchiveProfileRoots(; schemas = "episteme/profile/schemas"),
        )
        child_report = validate(profile_child)
        @test !isvalid(child_report)
        @test any(d -> d.code === :invalid_archive_root, child_report.diagnostics)
        child_path = joinpath(dir, "profile-child.ah5")
        @test_throws ArgumentError write_archive(child_path; profile = profile_child)
        @test !ispath(child_path)

        outside = ArchiveProfile(;
            roots = ArchiveProfileRoots(; schemas = "domain/schemas"),
        )
        outside_report = validate(outside)
        @test !isvalid(outside_report)
        @test any(d -> d.code === :invalid_archive_root, outside_report.diagnostics)
        outside_path = joinpath(dir, "outside.ah5")
        @test_throws ArgumentError write_archive(outside_path; profile = outside)
        @test !ispath(outside_path)

        overlapping = ArchiveProfile(;
            roots = ArchiveProfileRoots(
                schemas = "episteme/metadata/schemas",
                history = "episteme/metadata",
            ),
        )
        overlap_report = validate(overlapping)
        @test !isvalid(overlap_report)
        @test any(d -> d.code === :invalid_archive_root, overlap_report.diagnostics)
        overlap_path = joinpath(dir, "overlap.ah5")
        @test_throws ArgumentError write_archive(overlap_path; profile = overlapping)
        @test !ispath(overlap_path)
    end
end
