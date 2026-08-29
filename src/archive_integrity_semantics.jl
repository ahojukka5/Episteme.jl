# ---------------------------------------------------------------------------
# Fail-closed semantic checks for optional AH5 integrity trust records (#77)
# ---------------------------------------------------------------------------

function _require_persisted_integrity(condition::Bool, message::AbstractString)
    condition || throw(ArgumentError(String(message)))
    return nothing
end

function _is_sha256_content_id(value)
    value isa ContentId || return false
    text = value.value
    startswith(text, "sha256:") || return false
    hex = text[8:end]
    ncodeunits(hex) == 64 || return false
    return all(c -> ('0' <= c <= '9') || ('a' <= c <= 'f'), hex)
end

function _validate_persisted_integrity_row(
    row::IntegrityDependencyRow,
    requested_level::Symbol,
)
    _require_persisted_integrity(
        row.bytes_checked >= 0,
        "persisted integrity bytes_checked must be non-negative",
    )
    _require_persisted_integrity(
        isempty(row.diagnostics),
        "persisted integrity dependency rows must not contain diagnostics",
    )

    if row.kind === :object
        _require_persisted_integrity(
            row.availability === :envelope_only,
            "persisted object integrity row must be envelope_only",
        )
        _require_persisted_integrity(row.object_id !== nothing, "object integrity row lacks ObjectId")
        _require_persisted_integrity(row.revision_id !== nothing, "object integrity row lacks RevisionId")
        _require_persisted_integrity(row.schema !== nothing, "object integrity row lacks SchemaRef")
        _require_persisted_integrity(row.content_id !== nothing, "object integrity row lacks ContentId")
        _require_persisted_integrity(
            _is_sha256_content_id(row.content_id),
            "object integrity row requires a canonical sha256 ContentId",
        )
        _require_persisted_integrity(row.artifact === nothing, "object integrity row must not carry ArtifactRef")
        _require_persisted_integrity(row.verified_level === :none, "envelope object bytes were not verified")
        _require_persisted_integrity(row.bytes_checked == 0, "envelope object row must report zero bytes checked")
    elseif row.kind === :schema
        _require_persisted_integrity(
            row.availability === :embedded_schema,
            "persisted schema integrity row must be embedded_schema",
        )
        _require_persisted_integrity(row.object_id === nothing, "schema integrity row must not carry ObjectId")
        _require_persisted_integrity(row.revision_id === nothing, "schema integrity row must not carry RevisionId")
        _require_persisted_integrity(row.schema !== nothing, "schema integrity row lacks SchemaRef")
        _require_persisted_integrity(row.content_id !== nothing, "schema integrity row lacks canonical ContentId")
        _require_persisted_integrity(
            _is_sha256_content_id(row.content_id),
            "schema integrity row requires a canonical sha256 ContentId",
        )
        _require_persisted_integrity(row.artifact === nothing, "schema integrity row must not carry ArtifactRef")
        _require_persisted_integrity(row.verified_level === :none, "schema hash identity is not byte verification")
        _require_persisted_integrity(row.bytes_checked == 0, "schema integrity row must report zero bytes checked")
    elseif row.kind === :external
        _require_persisted_integrity(
            row.availability === :external_required,
            "persisted external integrity row must be external_required",
        )
        _require_persisted_integrity(row.object_id !== nothing, "external integrity row lacks ObjectId")
        _require_persisted_integrity(row.schema === nothing, "external integrity row must not carry SchemaRef")
        _require_persisted_integrity(row.content_id !== nothing, "external integrity row lacks ContentId")
        _require_persisted_integrity(
            _is_sha256_content_id(row.content_id),
            "external integrity row requires a sha256 ContentId",
        )
        _require_persisted_integrity(row.artifact !== nothing, "external integrity row lacks ArtifactRef")
        _require_persisted_integrity(
            row.verified_level === requested_level,
            "clean persisted external row must establish the requested verification level",
        )
        requested_level === :metadata && _require_persisted_integrity(
            row.bytes_checked == 0,
            "metadata verification must report zero content bytes checked",
        )
    else
        throw(ArgumentError("unsupported persisted integrity dependency kind :$(row.kind)"))
    end
    return row
end

function _validate_persisted_integrity_manifest(manifest::RevisionIntegrityManifest)
    _verification_level(manifest.requested_level)
    _require_persisted_integrity(manifest.valid, "persisted revision integrity manifest is not valid")
    _require_persisted_integrity(
        isempty(manifest.diagnostics),
        "persisted revision integrity manifests must not contain diagnostics",
    )
    for row in manifest.dependencies
        _validate_persisted_integrity_row(row, manifest.requested_level)
    end
    return manifest
end

function _row_revision_key(row::IntegrityDependencyRow)
    return (
        row.object_id === nothing ? "" : row.object_id.value,
        row.revision_id === nothing ? "" : row.revision_id.value,
    )
end

function _entry_revision_key(entry::ManifestEntry)
    return (
        entry.object_id.value,
        entry.revision_id === nothing ? "" : entry.revision_id.value,
    )
end

function _schema_row_key(row::IntegrityDependencyRow)
    row.schema === nothing && return ("", "", "")
    return _integrity_schema_key(row.schema)
end

function _artifact_persisted_identity(artifact::ArtifactRef)
    return (
        artifact.kind,
        artifact.path,
        artifact.uri,
        artifact.description,
    )
end

function _unique_integrity_rows(rows, keyfun, label)
    result = Dict{Any,IntegrityDependencyRow}()
    for row in rows
        key = keyfun(row)
        haskey(result, key) && throw(ArgumentError(
            "duplicate $label integrity dependency $(repr(key))",
        ))
        result[key] = row
    end
    return result
end

function _refuse_manifest_archive_mismatch(
    manifest::RevisionIntegrityManifest,
    graph::ArchiveGraph,
    schemas::SchemaRegistry,
    externals::Vector{ExternalRequirement},
)
    selected = inspect(graph, manifest.revision_id; externals = externals)
    errors = [d for d in selected.diagnostics if d.severity === :error]
    isempty(errors) || throw(ArgumentError(
        "cannot bind integrity manifest $(manifest.revision_id.value) to an invalid selected revision: $(Tuple(d.code for d in errors))",
    ))

    object_rows = _unique_integrity_rows(
        [row for row in manifest.dependencies if row.kind === :object],
        _row_revision_key,
        "object",
    )
    external_rows = _unique_integrity_rows(
        [row for row in manifest.dependencies if row.kind === :external],
        _row_revision_key,
        "external",
    )
    schema_rows = _unique_integrity_rows(
        [row for row in manifest.dependencies if row.kind === :schema],
        _schema_row_key,
        "schema",
    )

    expected_objects = 0
    expected_externals = 0
    expected_schemas = Dict{Tuple{String,String,String},SchemaRef}()
    for entry in selected.entries
        if entry.availability === :external_required
            expected_externals += 1
            key = _entry_revision_key(entry)
            row = get(external_rows, key, nothing)
            row === nothing && throw(ArgumentError(
                "integrity manifest lacks external dependency $(repr(key)) from selected revision",
            ))
            if entry.content_id !== nothing
                _require_persisted_integrity(
                    row.content_id == entry.content_id,
                    "external integrity ContentId disagrees with selected revision dependency $(repr(key))",
                )
            end
            entry.artifact === nothing && throw(ArgumentError(
                "selected external dependency $(repr(key)) lacks ArtifactRef",
            ))
            _require_persisted_integrity(
                _artifact_persisted_identity(row.artifact) == _artifact_persisted_identity(entry.artifact),
                "external integrity ArtifactRef disagrees with selected revision dependency $(repr(key))",
            )
        else
            expected_objects += 1
            entry.object === nothing && throw(ArgumentError(
                "selected revision dependency $(entry.object_id.value) has no resolved object envelope",
            ))
            key = _entry_revision_key(entry)
            row = get(object_rows, key, nothing)
            row === nothing && throw(ArgumentError(
                "integrity manifest lacks object dependency $(repr(key)) from selected revision",
            ))
            _require_persisted_integrity(
                row.content_id == entry.content_id,
                "object integrity ContentId disagrees with archive envelope $(repr(key))",
            )
            _require_persisted_integrity(
                row.schema == entry.object.schema,
                "object integrity SchemaRef disagrees with archive envelope $(repr(key))",
            )
            ref = entry.object.schema
            expected_schemas[_integrity_schema_key(ref)] = ref
        end
    end

    _require_persisted_integrity(
        length(object_rows) == expected_objects,
        "integrity manifest contains object dependencies outside the selected revision closure",
    )
    _require_persisted_integrity(
        length(external_rows) == expected_externals,
        "integrity manifest contains external dependencies outside the selected revision closure",
    )
    _require_persisted_integrity(
        length(schema_rows) == length(expected_schemas),
        "integrity manifest schema dependency set does not match the selected revision closure",
    )

    for (key, ref) in expected_schemas
        row = get(schema_rows, key, nothing)
        row === nothing && throw(ArgumentError(
            "integrity manifest lacks schema dependency $(schema_kind(ref)) version $(ref.version)",
        ))
        definitions = SchemaDefinition[
            definition for definition in schemas.entries if definition.schema == ref
        ]
        length(definitions) == 1 || throw(ArgumentError(
            "archive schema registry does not contain exactly one definition for $(schema_kind(ref)) version $(ref.version)",
        ))
        expected = canonical_content_id(only(definitions))
        _require_persisted_integrity(
            row.content_id == expected,
            "persisted schema ContentId does not match the archive's embedded schema $(schema_kind(ref)) version $(ref.version)",
        )
    end
    return manifest
end

function _refuse_integrity_archive_mismatch(
    manifests::Vector{RevisionIntegrityManifest},
    graph,
    schemas,
    externals,
)
    graph isa ArchiveGraph || throw(ArgumentError(
        "persisting revision integrity manifests requires graph=ArchiveGraph",
    ))
    schemas isa SchemaRegistry || throw(ArgumentError(
        "persisting revision integrity manifests requires schemas=SchemaRegistry",
    ))
    external_values = _typed_vector(ExternalRequirement, externals, "external requirements")
    for manifest in manifests
        _refuse_manifest_archive_mismatch(manifest, graph, schemas, external_values)
    end
    return manifests
end

# `_integrity_manifests` normalizes writer input to this exact vector type, so
# this method adds semantic preflight and then delegates to the base storage
# checks in archive_integrity_persistence.jl.
function _refuse_unstorable_integrity(manifests::Vector{RevisionIntegrityManifest})
    isempty(manifests) && throw(ArgumentError(
        "at least one revision integrity manifest is required for integrity persistence",
    ))
    for manifest in manifests
        _validate_persisted_integrity_manifest(manifest)
    end
    return invoke(_refuse_unstorable_integrity, Tuple{Any}, manifests)
end

# This more specific writer is the public path for the concrete manifest type.
# It binds trust records to the exact archive graph/schema metadata before the
# core writer creates a file. The single-manifest overload normalizes to this
# vector type automatically.
function write_archive(
    path::AbstractString,
    manifests::AbstractVector{RevisionIntegrityManifest};
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

# JLD2 plain=true returns the NamedTuple records written by
# `_integrity_manifest_storage`. Re-check semantic invariants after the generic
# primitive-column decoder so a crafted `valid=true` record cannot be trusted.
function _restore_integrity_manifest(nt::NamedTuple)
    manifest = invoke(_restore_integrity_manifest, Tuple{Any}, nt)
    return _validate_persisted_integrity_manifest(manifest)
end
