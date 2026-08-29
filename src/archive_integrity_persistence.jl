# ---------------------------------------------------------------------------
# Optional AH5 persistence for validated revision integrity manifests (#77)
# ---------------------------------------------------------------------------

const AH5_INTEGRITY_FEATURE = :integrity_manifest
const AH5_INTEGRITY_KEY = "episteme/integrity"

"""
    ArchiveIntegrityInspection <: AbstractValidationReport

Generic `plain=true` view of revision-integrity manifests stored in one AH5
archive. The core `ArchiveInspection` contract remains unchanged; this optional
view is requested explicitly with `inspect_archive(path, RevisionIntegrityManifest)`.
"""
struct ArchiveIntegrityInspection <: AbstractValidationReport
    path::String
    identified::Bool
    feature_declared::Bool
    valid::Bool
    manifests::Vector{RevisionIntegrityManifest}
    diagnostics::Vector{DiagnosticMessage}
end

Base.isvalid(view::ArchiveIntegrityInspection) = view.valid

function _integrity_manifests(values)
    return _typed_vector(RevisionIntegrityManifest, values, "revision integrity manifests")
end

function _integrity_profile(profile::ArchiveProfile)
    AH5_INTEGRITY_FEATURE in profile.required_features && throw(ArgumentError(
        "integrity manifests are an optional AH5 v1 feature and must not be declared required",
    ))
    features = Symbol[]
    for feature in profile.features
        feature in features || push!(features, feature)
    end
    AH5_INTEGRITY_FEATURE in features || push!(features, AH5_INTEGRITY_FEATURE)
    return ArchiveProfile(;
        magic = profile.magic,
        profile_version = profile.profile_version,
        archive_id = profile.archive_id,
        created_at = profile.created_at,
        creator = profile.creator,
        features = Tuple(features),
        required_features = profile.required_features,
        roots = profile.roots,
        package_version = profile.package_version,
    )
end

function _path_overlap(a::AbstractString, b::AbstractString)
    left = String(strip(a))
    right = String(strip(b))
    return left == right ||
        startswith(left, string(right, "/")) ||
        startswith(right, string(left, "/"))
end

function _refuse_integrity_root_collision(profile::ArchiveProfile)
    for (name, root) in (
        (:namespaces, profile.roots.namespaces),
        (:schemas, profile.roots.schemas),
        (:history, profile.roots.history),
        (:provenance, profile.roots.provenance),
        (:externals, profile.roots.externals),
    )
        _path_overlap(root, AH5_INTEGRITY_KEY) || continue
        throw(ArgumentError(
            "AH5 $name root $(repr(root)) overlaps optional integrity root $(repr(AH5_INTEGRITY_KEY))",
        ))
    end
    return profile
end

function _refuse_unstorable_integrity(manifests)
    seen = Set{String}()
    for manifest in manifests
        isvalid(manifest) || throw(ArgumentError(
            "refusing to persist invalid revision integrity manifest $(manifest.revision_id.value)",
        ))
        isempty(manifest.diagnostics) || throw(ArgumentError(
            "refusing to persist integrity manifest $(manifest.revision_id.value) with diagnostics; only clean successful manifests are persistent trust records",
        ))
        manifest.revision_id.value in seen && throw(ArgumentError(
            "duplicate revision integrity manifest $(manifest.revision_id.value)",
        ))
        push!(seen, manifest.revision_id.value)
        for row in manifest.dependencies
            isempty(row.diagnostics) || throw(ArgumentError(
                "refusing to persist integrity dependency with diagnostics for revision $(manifest.revision_id.value)",
            ))
            if row.artifact !== nothing && !isempty(keys(row.artifact.metadata))
                throw(ArgumentError(
                    "integrity persistence currently requires empty ArtifactRef metadata to remain lossless under the plain AH5 representation",
                ))
            end
        end
    end
    return manifests
end

function _optional_id_text(value)
    return value === nothing ? "" : value.value
end

function _optional_schema_parts(schema)
    schema === nothing && return ("", "", "")
    return (String(schema.namespace_id), schema.schema_id, schema.version)
end

function _optional_artifact_parts(artifact)
    artifact === nothing && return ("", "", "", "")
    return (
        String(artifact.kind),
        artifact.path === nothing ? "" : artifact.path,
        artifact.uri === nothing ? "" : artifact.uri,
        artifact.description,
    )
end

function _integrity_manifest_storage(manifest::RevisionIntegrityManifest)
    dep_kind = String[]
    dep_object_id = String[]
    dep_revision_id = String[]
    dep_schema_namespace = String[]
    dep_schema_id = String[]
    dep_schema_version = String[]
    dep_content_id = String[]
    dep_availability = String[]
    dep_artifact_kind = String[]
    dep_artifact_path = String[]
    dep_artifact_uri = String[]
    dep_artifact_description = String[]
    dep_verified_level = String[]
    dep_bytes_checked = Int64[]

    for row in manifest.dependencies
        schema_ns, schema_id, schema_version = _optional_schema_parts(row.schema)
        artifact_kind, artifact_path, artifact_uri, artifact_description =
            _optional_artifact_parts(row.artifact)
        push!(dep_kind, String(row.kind))
        push!(dep_object_id, _optional_id_text(row.object_id))
        push!(dep_revision_id, _optional_id_text(row.revision_id))
        push!(dep_schema_namespace, schema_ns)
        push!(dep_schema_id, schema_id)
        push!(dep_schema_version, schema_version)
        push!(dep_content_id, _optional_id_text(row.content_id))
        push!(dep_availability, String(row.availability))
        push!(dep_artifact_kind, artifact_kind)
        push!(dep_artifact_path, artifact_path)
        push!(dep_artifact_uri, artifact_uri)
        push!(dep_artifact_description, artifact_description)
        push!(dep_verified_level, String(row.verified_level))
        push!(dep_bytes_checked, row.bytes_checked)
    end

    return (
        revision_id = manifest.revision_id.value,
        requested_level = String(manifest.requested_level),
        valid = manifest.valid,
        dependency_count = length(manifest.dependencies),
        dep_kind = dep_kind,
        dep_object_id = dep_object_id,
        dep_revision_id = dep_revision_id,
        dep_schema_namespace = dep_schema_namespace,
        dep_schema_id = dep_schema_id,
        dep_schema_version = dep_schema_version,
        dep_content_id = dep_content_id,
        dep_availability = dep_availability,
        dep_artifact_kind = dep_artifact_kind,
        dep_artifact_path = dep_artifact_path,
        dep_artifact_uri = dep_artifact_uri,
        dep_artifact_description = dep_artifact_description,
        dep_verified_level = dep_verified_level,
        dep_bytes_checked = dep_bytes_checked,
    )
end

function _integrity_string_column(value, count::Int, name::AbstractString)
    result = String[String(item) for item in value]
    length(result) == count || throw(ArgumentError(
        "AH5 integrity column $name has length $(length(result)), expected $count",
    ))
    return result
end

function _integrity_int_column(value, count::Int, name::AbstractString)
    result = Int64[Int64(item) for item in value]
    length(result) == count || throw(ArgumentError(
        "AH5 integrity column $name has length $(length(result)), expected $count",
    ))
    return result
end

function _restore_optional_schema(namespace, schema_id, version)
    parts = (String(namespace), String(schema_id), String(version))
    all(isempty, parts) && return nothing
    any(isempty, parts) && throw(ArgumentError("partial schema identity in AH5 integrity row"))
    return SchemaRef(Symbol(parts[1]), parts[2], parts[3])
end

function _restore_optional_artifact(kind, path, uri, description)
    values = (String(kind), String(path), String(uri), String(description))
    if isempty(values[1])
        all(isempty, values) || throw(ArgumentError("artifact fields present without artifact kind"))
        return nothing
    end
    return ArtifactRef(
        Symbol(values[1]);
        path = isempty(values[2]) ? nothing : values[2],
        uri = isempty(values[3]) ? nothing : values[3],
        description = values[4],
    )
end

function _restore_integrity_manifest(nt)
    _as_bool(nt.valid) || throw(ArgumentError("persisted revision integrity manifest is not valid"))
    count = Int(nt.dependency_count)
    count >= 0 || throw(ArgumentError("negative AH5 integrity dependency count"))

    kinds = _integrity_string_column(nt.dep_kind, count, "dep_kind")
    object_ids = _integrity_string_column(nt.dep_object_id, count, "dep_object_id")
    revision_ids = _integrity_string_column(nt.dep_revision_id, count, "dep_revision_id")
    schema_ns = _integrity_string_column(nt.dep_schema_namespace, count, "dep_schema_namespace")
    schema_ids = _integrity_string_column(nt.dep_schema_id, count, "dep_schema_id")
    schema_versions = _integrity_string_column(nt.dep_schema_version, count, "dep_schema_version")
    content_ids = _integrity_string_column(nt.dep_content_id, count, "dep_content_id")
    availability = _integrity_string_column(nt.dep_availability, count, "dep_availability")
    artifact_kinds = _integrity_string_column(nt.dep_artifact_kind, count, "dep_artifact_kind")
    artifact_paths = _integrity_string_column(nt.dep_artifact_path, count, "dep_artifact_path")
    artifact_uris = _integrity_string_column(nt.dep_artifact_uri, count, "dep_artifact_uri")
    artifact_descriptions = _integrity_string_column(
        nt.dep_artifact_description, count, "dep_artifact_description",
    )
    verified_levels = _integrity_string_column(nt.dep_verified_level, count, "dep_verified_level")
    bytes_checked = _integrity_int_column(nt.dep_bytes_checked, count, "dep_bytes_checked")

    rows = IntegrityDependencyRow[]
    for index in 1:count
        object_id = isempty(object_ids[index]) ? nothing : ObjectId(object_ids[index])
        revision_id = isempty(revision_ids[index]) ? nothing : RevisionId(revision_ids[index])
        schema = _restore_optional_schema(
            schema_ns[index], schema_ids[index], schema_versions[index],
        )
        content_id = isempty(content_ids[index]) ? nothing : ContentId(content_ids[index])
        artifact = _restore_optional_artifact(
            artifact_kinds[index], artifact_paths[index], artifact_uris[index], artifact_descriptions[index],
        )
        push!(rows, _integrity_row(
            Symbol(kinds[index]);
            object_id = object_id,
            revision_id = revision_id,
            schema = schema,
            content_id = content_id,
            availability = Symbol(availability[index]),
            artifact = artifact,
            verified_level = Symbol(verified_levels[index]),
            bytes_checked = bytes_checked[index],
        ))
    end

    requested = _verification_level(Symbol(nt.requested_level))
    return RevisionIntegrityManifest(
        RevisionId(String(nt.revision_id)),
        requested,
        true,
        rows,
        DiagnosticMessage[],
    )
end

function _profile_with_integrity(profile, kwargs)
    if profile === nothing
        return _integrity_profile(ArchiveProfile(; kwargs...))
    end
    isempty(kwargs) || throw(ArgumentError(
        "pass either profile= or ArchiveProfile keywords, not both",
    ))
    profile isa ArchiveProfile || throw(ArgumentError(
        "profile must be ArchiveProfile, got $(typeof(profile))",
    ))
    return _integrity_profile(profile)
end

"""
    write_archive(path, manifest::RevisionIntegrityManifest; kwargs...)
    write_archive(path, manifests::AbstractVector{<:RevisionIntegrityManifest}; kwargs...)

Create a normal JLD2-backed AH5 archive and append clean, successful revision
integrity manifests under the optional `episteme/integrity` feature. If the
integrity append fails, the newly-created file is removed rather than published
partially.
"""
function write_archive(
    path::AbstractString,
    manifest::RevisionIntegrityManifest;
    kwargs...,
)
    return write_archive(path, RevisionIntegrityManifest[manifest]; kwargs...)
end

function write_archive(
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

function _empty_integrity_inspection(path, identified, declared, diagnostics)
    valid = identified && !any(diagnostic -> diagnostic.severity === :error, diagnostics)
    return ArchiveIntegrityInspection(
        String(path),
        identified,
        declared,
        valid,
        RevisionIntegrityManifest[],
        diagnostics,
    )
end

"""
    inspect_archive(path, RevisionIntegrityManifest) -> ArchiveIntegrityInspection

Inspect the optional AH5 integrity root through JLD2 `plain=true`. Old archives
without the optional feature remain valid and return an empty manifest list.
The root is interpreted only when the profile explicitly declares the feature.
"""
function inspect_archive(
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

function validate(view::ArchiveIntegrityInspection)
    return ValidationReport(
        :ah5_integrity,
        view.valid,
        view.diagnostics,
        (;
            path = view.path,
            identified = view.identified,
            feature_declared = view.feature_declared,
            manifests = length(view.manifests),
        ),
    )
end

function report(view::ArchiveIntegrityInspection)
    return ObjectReport(
        :ah5_integrity,
        view.feature_declared ?
            "AH5 archive contains $(length(view.manifests)) revision integrity manifest(s)." :
            "AH5 archive has no declared revision integrity feature.",
        to_namedtuple(view),
        view.diagnostics,
        ArtifactRef[],
    )
end

to_namedtuple(view::ArchiveIntegrityInspection) = (
    path = view.path,
    identified = view.identified,
    feature_declared = view.feature_declared,
    valid = view.valid,
    manifests = Tuple(to_namedtuple.(view.manifests)),
    diagnostics = Tuple(to_namedtuple.(view.diagnostics)),
)
