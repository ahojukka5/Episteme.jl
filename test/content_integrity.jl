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

function _warmed_canonical_digest_alloc(value)
    canonical_digest(value)
    return @allocated canonical_digest(value)
end

@testset "streamed canonical digest" begin
    nested = (;
        label = "nested",
        values = [1.25, -0.0, Inf, -Inf, NaN],
        meta = (n = typemin(Int64), ok = true, name = "mesh"),
        items = (Int32(7), "mesh", :a),
        mapping = Dict{String,Any}("b" => 2, "a" => "mesh"),
    )
    materialized = collect(Episteme.SHA.sha256(canonical_bytes(nested)))
    @test canonical_digest(nested) == materialized
    policy = CanonicalHashPolicy(; version = "episteme-canonical-v2-test")
    @test canonical_digest(nested; policy) ==
        collect(Episteme.SHA.sha256(canonical_bytes(nested; policy)))
    @test canonical_digest(nested; policy) != canonical_digest(nested)

    # Pinned episteme-canonical-v1 digests. These lock the byte layout; the
    # streamed digest and canonical_bytes must both keep producing them.
    @test bytes2hex(canonical_digest(typemin(Int64))) ==
        "4b83e839ba7ff21baad396dec968d16072ae28f50807e976776cdda626fa2716"
    @test bytes2hex(canonical_digest(typemax(UInt128))) ==
        "87e122a871349d0ef242f0ef4bedb654904807a5954f335eae01a0d16f39756c"
    @test bytes2hex(canonical_digest(big"123456789012345678901234567890")) ==
        "a9f3a33bff8db5de4c7084ca48d3bcc647951b599c437dfc12d524610e45223a"
    @test bytes2hex(canonical_digest(-0.0)) ==
        "24bdb14476c757e5c4dc47d0a8d059a2776f11971c8f015b9e7dce212a7f5dde"
    @test bytes2hex(canonical_digest(1.5)) ==
        "e5b02bc17042ed75106a3e250e89eb12c089767a73fe1636d25cd3e16ca74f33"
    @test bytes2hex(canonical_digest(NaN)) ==
        "414903fe72e36a71dcb18a22c2906c7c66fdca155b149c4eadc2109c4e7d0943"
    pinned = (;
        label = "nested",
        values = [1.25, -0.0, Inf],
        meta = (n = 2, ok = true),
    )
    @test bytes2hex(canonical_digest(pinned)) ==
        "6a295e63d8a5a301388a238617add4a20ebcf7aa641efb5bebb5ee898a87bb9a"
    wide = (; record = (name = "nested", values = fill(1.5, 4000)))
    @test bytes2hex(canonical_digest(wide)) ==
        "e7cecc8955a3f0c1fa01cfd4c3e28cb871e85135fc7a44184ec73f6019b5247b"
    @test canonical_digest(wide) == collect(Episteme.SHA.sha256(canonical_bytes(wide)))
    @test occursin(string(typemin(Int64)), String(canonical_bytes(typemin(Int64))))
    @test occursin(string(typemax(UInt128)), String(canonical_bytes(typemax(UInt128))))
    @test occursin(
        string(reinterpret(UInt64, 1.5); base = 16, pad = 16),
        String(canonical_bytes(1.5)),
    )

    small = (; record = (name = "nested", values = fill(1.5, 2_000)))
    large = (; record = (name = "nested", values = fill(1.5, 20_000)))
    _warmed_canonical_digest_alloc(small)
    alloc_small = _warmed_canonical_digest_alloc(small)
    alloc_large = _warmed_canonical_digest_alloc(large)
    transcript = length(canonical_bytes(large))
    @test transcript > 400_000
    @test alloc_large * 8 < transcript
    @test alloc_large < 64 * 1024
    @test alloc_large <= alloc_small * 2
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
