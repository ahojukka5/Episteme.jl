@testset "canonical logical content hashing" begin
    left = Dict{Symbol,Any}()
    left[:b] = 2
    left[:a] = "mesh"
    right = Dict{Symbol,Any}()
    right[:a] = "mesh"
    right[:b] = 2
    @test canonical_content_id(left) == canonical_content_id(right)

    @test canonical_content_id((; a = 1, b = 2)) ==
        canonical_content_id((; b = 2, a = 1))
    @test canonical_content_id(Int32(7)) == canonical_content_id(Int64(7))
    @test canonical_content_id(Float32(1.5)) == canonical_content_id(Float64(1.5))
    @test canonical_content_id(-0.0) == canonical_content_id(0.0)

    values = [1, 2, 3]
    @test canonical_content_id(values) == canonical_content_id(Any[1, 2, 3])
    @test canonical_content_id(values) == canonical_content_id(view(values, :))
    @test canonical_content_id(values) != canonical_content_id([1, 2, 4])
    @test canonical_content_id(values) != canonical_content_id(reshape([1, 2, 3], 1, 3))

    id = canonical_content_id((; value = 42))
    @test startswith(id.value, "sha256:")
    @test length(id.value) == length("sha256:") + 64
    @test canonical_content_id((; value = 42)) != canonical_content_id((; value = 43))

    policy_v2 = CanonicalHashPolicy(; version = "episteme-canonical-v2-test")
    @test canonical_content_id((; value = 42)) !=
        canonical_content_id((; value = 42); policy = policy_v2)

    doc_a = PortableSemanticDocument(
        DocumentId("doc-a"),
        PortableNode[];
        metadata = (; a = 1, b = "same"),
    )
    doc_b = PortableSemanticDocument(
        DocumentId("doc-b"),
        PortableNode[];
        metadata = (; b = "same", a = 1),
    )
    @test canonical_content_id(doc_a) == canonical_content_id(doc_b)

    schema_a = _mesh_def(; package_version = "0.1.0")
    schema_b = _mesh_def(; package_version = "9.9.9")
    schema_v2 = _mesh_def(; version = "2.0.0", package_version = "9.9.9")
    @test canonical_content_id(schema_a) == canonical_content_id(schema_b)
    @test canonical_content_id(schema_a) != canonical_content_id(schema_v2)

    @test_throws ArgumentError canonical_content_id(DummyObject())
    @test_throws ArgumentError CanonicalHashPolicy(; algorithm = :md5)
end
