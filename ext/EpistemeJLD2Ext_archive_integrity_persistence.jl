# ---------------------------------------------------------------------------
# Optional integrity root (src/archive_integrity_persistence.jl)
#
# The single-manifest `write_archive` overload stays in the owner package: it
# only normalizes its argument and delegates here, and it fails closed through
# this method's stub when the extension is not loaded.
# ---------------------------------------------------------------------------

function Episteme.write_archive(
    path::AbstractString,
    manifests::AbstractVector{<:RevisionIntegrityManifest};
    graph = nothing,
    namespaces = nothing,
    schemas = nothing,
    externals = ExternalRequirement[],
    profile = nothing,
    kwargs...,
)
    ispath(path) && throw(ArgumentError("archive already exists: $path"))
    integrity = _integrity_manifests(manifests)
    _refuse_unstorable_integrity(integrity)
    profile_record = _profile_with_integrity(profile, kwargs)
    _refuse_integrity_root_collision(profile_record)

    created = false
    try
        write_archive(
            path;
            graph = graph,
            namespaces = namespaces,
            schemas = schemas,
            externals = externals,
            profile = profile_record,
        )
        created = true
        JLD2.jldopen(path, "r+") do file
            _write_indexed!(
                file,
                AH5_INTEGRITY_KEY,
                integrity,
                _integrity_manifest_storage,
            )
        end
    catch
        created && ispath(path) && rm(path; force = true)
        rethrow()
    end
    return path
end

function Episteme.inspect_archive(
    path::AbstractString,
    ::Type{RevisionIntegrityManifest},
)
    base = inspect_archive(path)
    diagnostics = copy(base.diagnostics)
    if !base.identified || base.profile === nothing
        return _empty_integrity_inspection(path, base.identified, false, diagnostics)
    end
    if any(diagnostic -> diagnostic.severity === :error, diagnostics)
        return _empty_integrity_inspection(path, true, false, diagnostics)
    end

    declared = AH5_INTEGRITY_FEATURE in base.profile.features
    declared || return _empty_integrity_inspection(path, true, false, diagnostics)

    manifests = RevisionIntegrityManifest[]
    try
        JLD2.jldopen(path, "r"; plain = true) do file
            _jld2_get(file, _count_key(AH5_INTEGRITY_KEY)) === nothing && throw(ArgumentError(
                "AH5 profile declares integrity manifests but $(AH5_INTEGRITY_KEY)/count is missing",
            ))
            append!(manifests, _read_indexed(
                RevisionIntegrityManifest,
                file,
                AH5_INTEGRITY_KEY,
                _restore_integrity_manifest,
            ))
        end
        seen = Set{String}()
        for manifest in manifests
            manifest.revision_id.value in seen && throw(ArgumentError(
                "duplicate stored revision integrity manifest $(manifest.revision_id.value)",
            ))
            push!(seen, manifest.revision_id.value)
        end
    catch err
        push!(diagnostics, error_diagnostic(
            :corrupt_integrity_manifest,
            "AH5 integrity metadata is corrupt";
            path = String(path),
            reason = sprint(showerror, err),
        ))
        empty!(manifests)
    end

    valid = !any(diagnostic -> diagnostic.severity === :error, diagnostics)
    return ArchiveIntegrityInspection(
        String(path),
        true,
        true,
        valid,
        manifests,
        diagnostics,
    )
end
