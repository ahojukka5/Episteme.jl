# ---------------------------------------------------------------------------
# Tiered verification of authoritative external files (#73 / parent #42)
+# ---------------------------------------------------------------------------

const EXTERNAL_VERIFICATION_LEVELS = (:metadata, :sample, :full)
const EXTERNAL_VERIFIED_LEVELS = (:none, :metadata, :sample, :full)
const EXTERNAL_SAMPLE_VERSION = "episteme-external-sample-v1"

"""
    ExternalIntegrityRecord

Immutable expected integrity facts for one local authoritative external file.
The strong `content_id` is a SHA-256 digest of all bytes. `sample_id` hashes a
versioned deterministic transcript of selected byte ranges and is never a
substitute for the full content identity.
"""
struct ExternalIntegrityRecord
    object_id::ObjectId
    artifact::ArtifactRef
    content_id::ContentId
    size::Int64
    sample_bytes::Int
    sample_offsets::Tuple{Vararg{Int64}}
    sample_id::ContentId
end

"""
    ExternalVerificationReport <: AbstractValidationReport

Result of an explicit external-artifact verification request. `verified_level`
is the strongest level actually established by this check; `bytes_checked`
makes verification cost visible.
"""
struct ExternalVerificationReport <: AbstractValidationReport
    object_id::ObjectId
    artifact::ArtifactRef
    requested_level::Symbol
    verified_level::Symbol
    valid::Bool
    bytes_checked::Int64
    total_bytes::Int64
    diagnostics::Vector{DiagnosticMessage}
end

Base.isvalid(report::ExternalVerificationReport) = report.valid

function _verification_level(level::Symbol)
    level in EXTERNAL_VERIFICATION_LEVELS || throw(ArgumentError(
        "verification level must be one of $EXTERNAL_VERIFICATION_LEVELS, got :$level",
    ))
    return level
end

function _local_artifact_path(artifact::ArtifactRef)
    path = artifact.path
    path === nothing && throw(ArgumentError(
        "external verification currently requires ArtifactRef.path; remote URI verification is not implemented",
    ))
    return path
end

function _sha256_content_id(digest)
    return ContentId("sha256:" * bytes2hex(digest))
end

"""
    external_file_content_id(path) -> ContentId

Stream the complete file through SHA-256. File layout outside the byte stream
(path name, filesystem metadata, archive placement) does not affect identity.
"""
function external_file_content_id(path::AbstractString)
    isfile(path) || throw(ArgumentError("external artifact is not a file: $path"))
    digest = open(path, "r") do io
        SHA.sha256(io)
    end
    return _sha256_content_id(digest)
end

function _sample_offsets(size::Int64, sample_bytes::Int, sample_count::Int)
    sample_bytes > 0 || throw(ArgumentError("sample_bytes must be positive"))
    sample_count > 0 || throw(ArgumentError("sample_count must be positive"))
    size <= 0 && return ()
    block = min(Int64(sample_bytes), size)
    max_start = size - block
    sample_count == 1 && return (Int64(0),)
    offsets = Int64[
        fld(Int64(i) * max_start, Int64(sample_count - 1))
        for i in 0:(sample_count - 1)
    ]
    return Tuple(unique(offsets))
end

function _sample_transcript(path, size::Int64, offsets, sample_bytes::Int)
    io = IOBuffer()
    write(io, codeunits(EXTERNAL_SAMPLE_VERSION))
    write(io, UInt8(';'))
    print(io, size)
    write(io, UInt8(';'))
    print(io, sample_bytes)
    write(io, UInt8(';'))
    print(io, length(offsets))
    write(io, UInt8(';'))
    checked = Int64(0)
    open(path, "r") do file
        for offset in offsets
            offset >= 0 || throw(ArgumentError("sample offset must be non-negative"))
            offset <= size || throw(ArgumentError("sample offset exceeds file size"))
            n = Int(min(Int64(sample_bytes), size - offset))
            seek(file, offset)
            chunk = read(file, n)
            length(chunk) == n || throw(EOFError())
            print(io, offset)
            write(io, UInt8(':'))
            print(io, n)
            write(io, UInt8(':'))
            write(io, chunk)
            checked += n
        end
    end
    return take!(io), checked
end

function _sample_content_id(path, size::Int64, offsets, sample_bytes::Int)
    transcript, checked = _sample_transcript(path, size, offsets, sample_bytes)
    return _sha256_content_id(SHA.sha256(transcript)), checked
end

"""
    capture_external_integrity(requirement; sample_bytes=65536, sample_count=3)
        -> ExternalIntegrityRecord

Establish a strong identity for a local external artifact. This operation
performs one full streaming SHA-256 pass. If `requirement.content_id` is already
specified, it must agree with the observed bytes. A deterministic sample
fingerprint is captured for later cheaper `:sample` checks.
"""
function capture_external_integrity(
    requirement::ExternalRequirement;
    sample_bytes::Integer = 65536,
    sample_count::Integer = 3,
)
    sb = Int(sample_bytes)
    sc = Int(sample_count)
    sb > 0 || throw(ArgumentError("sample_bytes must be positive"))
    sc > 0 || throw(ArgumentError("sample_count must be positive"))
    path = _local_artifact_path(requirement.artifact)
    isfile(path) || throw(ArgumentError("external artifact is not a file: $path"))
    size = Int64(filesize(path))
    content_id = external_file_content_id(path)
    if requirement.content_id !== nothing && requirement.content_id != content_id
        throw(ArgumentError(
            "declared external content id $(requirement.content_id.value) does not match observed $(content_id.value)",
        ))
    end
    offsets = _sample_offsets(size, sb, sc)
    sample_id, _ = _sample_content_id(path, size, offsets, sb)
    return ExternalIntegrityRecord(
        requirement.object_id,
        requirement.artifact,
        content_id,
        size,
        sb,
        offsets,
        sample_id,
    )
end

function _external_report(
    record::ExternalIntegrityRecord,
    requested::Symbol,
    verified::Symbol,
    valid::Bool,
    bytes_checked::Integer,
    diagnostics,
)
    verified in EXTERNAL_VERIFIED_LEVELS || throw(ArgumentError(
        "verified level must be one of $EXTERNAL_VERIFIED_LEVELS",
    ))
    return ExternalVerificationReport(
        record.object_id,
        record.artifact,
        requested,
        verified,
        valid,
        Int64(bytes_checked),
        record.size,
        DiagnosticMessage[diagnostics...],
    )
end

"""
    verify_external(record; level=:full) -> ExternalVerificationReport

Verify a local external artifact at an explicit cost/strength level:

- `:metadata` checks file availability and byte size only (`bytes_checked == 0`);
- `:sample` additionally checks the deterministic sampled ranges;
- `:full` streams every byte through SHA-256.

A successful metadata/sample report never claims full verification.
"""
function verify_external(
    record::ExternalIntegrityRecord;
    level::Symbol = :full,
)
    requested = _verification_level(level)
    diagnostics = DiagnosticMessage[]
    path = record.artifact.path
    if path === nothing
        push!(diagnostics, error_diagnostic(
            :external_path_unavailable,
            "external artifact has no local path for verification";
            object_id = record.object_id.value,
            uri = record.artifact.uri,
        ))
        return _external_report(record, requested, :none, false, 0, diagnostics)
    end
    if !isfile(path)
        push!(diagnostics, error_diagnostic(
            :external_artifact_missing,
            "external artifact is missing: $path";
            object_id = record.object_id.value,
            path = path,
        ))
        return _external_report(record, requested, :none, false, 0, diagnostics)
    end

    observed_size = Int64(filesize(path))
    if observed_size != record.size
        push!(diagnostics, error_diagnostic(
            :external_size_mismatch,
            "external artifact size changed from $(record.size) to $observed_size bytes";
            object_id = record.object_id.value,
            path = path,
            expected_size = record.size,
            observed_size = observed_size,
        ))
        return _external_report(record, requested, :none, false, 0, diagnostics)
    end

    requested === :metadata &&
        return _external_report(record, requested, :metadata, true, 0, diagnostics)

    if requested === :sample
        observed, checked = _sample_content_id(
            path, record.size, record.sample_offsets, record.sample_bytes,
        )
        if observed != record.sample_id
            push!(diagnostics, error_diagnostic(
                :external_sample_mismatch,
                "sampled external artifact bytes do not match the recorded fingerprint";
                object_id = record.object_id.value,
                path = path,
                bytes_checked = checked,
            ))
            return _external_report(record, requested, :metadata, false, checked, diagnostics)
        end
        return _external_report(record, requested, :sample, true, checked, diagnostics)
    end

    observed = external_file_content_id(path)
    if observed != record.content_id
        push!(diagnostics, error_diagnostic(
            :external_hash_mismatch,
            "external artifact full SHA-256 does not match the recorded content identity";
            object_id = record.object_id.value,
            path = path,
            expected_content_id = record.content_id.value,
            observed_content_id = observed.value,
        ))
        return _external_report(record, requested, :metadata, false, record.size, diagnostics)
    end
    return _external_report(record, requested, :full, true, record.size, diagnostics)
end

function validate(record::ExternalIntegrityRecord)
    diagnostics = DiagnosticMessage[]
    record.size < 0 && push!(diagnostics, error_diagnostic(
        :invalid_external_integrity,
        "external integrity size must be non-negative";
        object_id = record.object_id.value,
    ))
    record.sample_bytes <= 0 && push!(diagnostics, error_diagnostic(
        :invalid_external_integrity,
        "external integrity sample_bytes must be positive";
        object_id = record.object_id.value,
    ))
    previous = Int64(-1)
    for offset in record.sample_offsets
        if offset < 0 || offset > record.size || offset <= previous
            push!(diagnostics, error_diagnostic(
                :invalid_external_integrity,
                "external sample offsets must be strictly increasing and within the file";
                object_id = record.object_id.value,
                offset = offset,
            ))
        end
        previous = offset
    end
    return ValidationReport(
        :external_integrity,
        isempty(diagnostics),
        diagnostics,
        (;
            object_id = record.object_id.value,
            size = record.size,
            sample_offsets = record.sample_offsets,
        ),
    )
end

function report(record::ExternalIntegrityRecord)
    return ObjectReport(
        :external_integrity,
        "External integrity record for $(record.object_id.value) ($(record.size) bytes).",
        to_namedtuple(record),
        DiagnosticMessage[],
        ArtifactRef[record.artifact],
    )
end

function report(result::ExternalVerificationReport)
    return ObjectReport(
        :external_verification,
        "External verification $(result.valid ? "passed" : "failed") at requested level :$(result.requested_level); strongest established level :$(result.verified_level).",
        to_namedtuple(result),
        result.diagnostics,
        ArtifactRef[result.artifact],
    )
end

to_namedtuple(record::ExternalIntegrityRecord) = (
    object_id = record.object_id.value,
    artifact = to_namedtuple(record.artifact),
    content_id = record.content_id.value,
    size = record.size,
    sample_bytes = record.sample_bytes,
    sample_offsets = record.sample_offsets,
    sample_id = record.sample_id.value,
)

to_namedtuple(result::ExternalVerificationReport) = (
    object_id = result.object_id.value,
    artifact = to_namedtuple(result.artifact),
    requested_level = result.requested_level,
    verified_level = result.verified_level,
    valid = result.valid,
    bytes_checked = result.bytes_checked,
    total_bytes = result.total_bytes,
    diagnostics = Tuple(to_namedtuple.(result.diagnostics)),
)
