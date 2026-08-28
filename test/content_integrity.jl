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

@testset "tiered local external artifact verification" begin
    mktempdir() do dir
        path = joinpath(dir, "artifact.bin")
        original = repeat(collect(UInt8(0):UInt8(255)), 16)
        write(path, original)
        requirement = ExternalRequirement(
            ObjectId("external-1");
            artifact = ArtifactRef(:binary; path = path, description = "authoritative bytes"),
        )
        record = capture_external_integrity(
            requirement;
            sample_bytes = 16,
            sample_count = 3,
        )
        @test isvalid(validate(record))
        @test record.size == 4096
        @test startswith(record.content_id.value, "sha256:")
        @test length(record.sample_offsets) == 3

        metadata = verify_external(record; level = :metadata)
        @test isvalid(metadata)
        @test metadata.requested_level === :metadata
        @test metadata.verified_level === :metadata
        @test metadata.bytes_checked == 0

        sample = verify_external(record; level = :sample)
        @test isvalid(sample)
        @test sample.verified_level === :sample
        @test sample.bytes_checked == 48
        @test sample.bytes_checked < sample.total_bytes

        full = verify_external(record; level = :full)
        @test isvalid(full)
        @test full.verified_level === :full
        @test full.bytes_checked == full.total_bytes == 4096

        # Same-size mutation outside the deterministic sample is invisible to
        # metadata and sample checks but is caught by full verification.
        open(path, "r+") do io
            seek(io, 100)
            write(io, UInt8(0xff))
        end
        @test isvalid(verify_external(record; level = :metadata))
        @test isvalid(verify_external(record; level = :sample))
        changed = verify_external(record; level = :full)
        @test !isvalid(changed)
        @test changed.verified_level === :metadata
        @test any(d -> d.code === :external_hash_mismatch, changed.diagnostics)

        # Restore and mutate a byte that is definitely in the first sample.
        open(path, "r+") do io
            seek(io, 100)
            write(io, original[101])
            seek(io, 0)
            write(io, UInt8(0x7f))
        end
        sampled_change = verify_external(record; level = :sample)
        @test !isvalid(sampled_change)
        @test sampled_change.verified_level === :metadata
        @test any(d -> d.code === :external_sample_mismatch, sampled_change.diagnostics)

        # Size changes fail before any content bytes are hashed.
        open(path, "a") do io
            write(io, UInt8(0x00))
        end
        resized = verify_external(record; level = :full)
        @test !isvalid(resized)
        @test resized.verified_level === :none
        @test resized.bytes_checked == 0
        @test any(d -> d.code === :external_size_mismatch, resized.diagnostics)

        rm(path)
        missing = verify_external(record; level = :metadata)
        @test !isvalid(missing)
        @test missing.verified_level === :none
        @test any(d -> d.code === :external_artifact_missing, missing.diagnostics)

        # Capture must honor an already-declared strong external content id.
        write(path, original)
        wrong = ExternalRequirement(
            ObjectId("external-2");
            content_id = ContentId("sha256:" * repeat("0", 64)),
            artifact = ArtifactRef(:binary; path = path),
        )
        @test_throws ArgumentError capture_external_integrity(wrong)

        declared = ExternalRequirement(
            ObjectId("external-3");
            content_id = external_file_content_id(path),
            artifact = ArtifactRef(:binary; path = path),
        )
        declared_record = capture_external_integrity(declared; sample_bytes = 8, sample_count = 1)
        @test declared_record.content_id == declared.content_id

        @test_throws ArgumentError verify_external(record; level = :bogus)
        @test_throws ArgumentError capture_external_integrity(requirement; sample_bytes = 0)
        @test_throws ArgumentError capture_external_integrity(
            ExternalRequirement(
                ObjectId("remote");
                artifact = ArtifactRef(:binary; uri = "https://example.invalid/file"),
            ),
        )
    end
end
