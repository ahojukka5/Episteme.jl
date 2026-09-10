using SHA

@testset "external verification rejects malformed sample plans" begin
    mktempdir() do directory
        path = joinpath(directory, "bytes.bin")
        write(path, "nonempty")
        requirement = ExternalRequirement(ObjectId("sample-plan");
            artifact=ArtifactRef(:binary; path))
        original = capture_external_integrity(requirement; sample_bytes=2)
        # A matching fingerprint for a zero-range transcript must not turn a
        # nonempty file into successful sample verification with zero reads.
        empty_fingerprint = ContentId("sha256:" * bytes2hex(
            SHA.sha256("episteme-external-sample-v1;8;2;0;")))
        for (size, block, offsets) in (
            (8, 2, ()), (8, 2, (8,)), (8, 2, (-1,)),
            (8, 2, (0, 0)), (8, 0, (0,)), (-1, 2, ()), (0, 2, (0,)),
        )
            record = ExternalIntegrityRecord(original.object_id, original.artifact,
                original.content_id, size, block, offsets, empty_fingerprint)
            @test !isvalid(validate(record))
            for level in (:metadata, :sample, :full)
                result = verify_external(record; level)
                @test !isvalid(result)
                @test result.verified_level === :none
                @test result.bytes_checked == 0
                @test any(d -> d.code === :invalid_external_integrity, result.diagnostics)
            end
        end

        # Empty files legitimately have no ranges. A sample block larger than
        # a short file is truncated to the available bytes and remains valid.
        for bytes in ("", "abc")
            write(path, bytes)
            record = capture_external_integrity(requirement; sample_bytes=16)
            @test isvalid(validate(record))
            for level in (:sample, :full)
                result = verify_external(record; level)
                @test isvalid(result)
                @test result.verified_level === level
                @test result.bytes_checked == sizeof(bytes)
            end
        end
    end
end
