# Delone's triangulation with no lifecycle call and no Oodi.
# Episteme is pinned only because Delone already imports it for
# report/validate. This script does not import or call that API.

import Pkg
Pkg.instantiate(; io = devnull)

using Test
using Delone

const SQUARE = [
    0.0 1.0 1.0 0.0
    0.0 0.0 1.0 1.0
]
const COLLINEAR = [
    0.0 1.0 2.0 3.0
    0.0 0.0 0.0 0.0
]

function _operation_source_is_domain_only()
    method = which(delaunay_triangulation, (Matrix{Float64},))
    method.module === Delone.Algorithms || return false
    file = String(method.file)
    occursin("Delone", file) || return false
    occursin("Episteme", file) && return false
    source = read(file, String)
    for needle in (
        "execute!",
        "commit!",
        "WorkingStore",
        "ArchiveGraph",
        "apply_operation",
        "Oodi",
    )
        occursin(needle, source) && return false
    end
    return true
end

function main()
    names = Set(id.name for id in keys(Base.loaded_modules))
    ts = @testset "Delone triangulation without orchestration" begin
        @test !isdefined(Main, :execute!)
        @test !isdefined(Main, :commit!)
        @test !isdefined(Main, :Plan)
        @test !isdefined(Main, :ArchiveGraph)
        @test !isdefined(Main, :Episteme)
        @test "Oodi" ∉ names
        @test "Maudslay" ∉ names
        @test "Irons" ∉ names
        @test _operation_source_is_domain_only()

        snapshot = delaunay_triangulation(SQUARE)
        @test snapshot isa MeshLevelSnapshot
        @test size(snapshot.volume_connectivity) == (3, 2)
        @test isvalid(validate(snapshot))
        @test Delone.Algorithms.exact_delaunay_invariants_2d(snapshot).valid
        digest = String(to_namedtuple(snapshot).content_digest)
        @test length(digest) == 64
        println("EPISTEME_DIRECT_DIGEST=" * digest)

        @test_throws ArgumentError delaunay_triangulation(COLLINEAR)
    end
    return ts.anynonpass ? 1 : 0
end

exit(main())
