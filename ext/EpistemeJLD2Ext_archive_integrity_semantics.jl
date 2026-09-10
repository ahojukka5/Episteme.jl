# ---------------------------------------------------------------------------
# Semantic preflight for the integrity writer (src/archive_integrity_semantics.jl)
#
# `_refuse_unstorable_integrity` and `_restore_integrity_manifest` keep their
# semantic methods in the owner package; only this file-creating writer moves.
# ---------------------------------------------------------------------------

# This more specific writer is the public path for the concrete manifest type.
# It binds trust records to the exact archive graph/schema metadata before the
# core writer creates a file. The single-manifest overload normalizes to this
# vector type automatically.
function Episteme.write_archive(
    path::AbstractString,
    manifests::AbstractVector{RevisionIntegrityManifest};
    graph = nothing,
    namespaces = nothing,
    schemas = nothing,
    externals = ExternalRequirement[],
    profile = nothing,
    software_environments = nothing,
    execution_contexts = nothing,
    kwargs...,
)
    ispath(path) && throw(ArgumentError("archive already exists: $path"))
    integrity = _integrity_manifests(manifests)
    _refuse_unstorable_integrity(integrity)
    _refuse_integrity_archive_mismatch(integrity, graph, schemas, externals)
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
            software_environments = software_environments,
            execution_contexts = execution_contexts,
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
