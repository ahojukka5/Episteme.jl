# ---------------------------------------------------------------------------
# Revision-scoped dependency integrity manifests (#75 / parent #42)
# ---------------------------------------------------------------------------

const INTEGRITY_DEPENDENCY_KINDS = (:object, :schema, :external)
const INTEGRITY_AVAILABILITY = (
    :envelope_only,
    :embedded_schema,
    :external_required,
    :missing,
    :ambiguous,
)

"""
    IntegrityDependencyRow

One dependency in a selected revision's integrity closure. Object rows carry
an expected envelope `ContentId`; schema rows carry the canonical schema hash;
external rows additionally report the strongest verification level actually
established and the number of bytes checked.
"""
struct IntegrityDependencyRow
    kind::Symbol
    object_id::Union{Nothing,ObjectId}
    revision_id::Union{Nothing,RevisionId}
    schema::Union{Nothing,SchemaRef}
    content_id::Union{Nothing,ContentId}
    availability::Symbol
    artifact::Union{Nothing,ArtifactRef}
    verified_level::Symbol
    bytes_checked::Int64
    diagnostics::Vector{DiagnosticMessage}
end

"""
    RevisionIntegrityManifest <: AbstractValidationReport

Deterministic integrity view of exactly one selected historical revision and
its visible dependency closure. `requested_level` applies to external file
verification; envelope-only object payloads are not falsely reported as byte
verified.
"""
struct RevisionIntegrityManifest <: AbstractValidationReport
    revision_id::RevisionId
    requested_level::Symbol
    valid::Bool
    dependencies::Vector{IntegrityDependencyRow}
    diagnostics::Vector{DiagnosticMessage}
end

Base.isvalid(manifest::RevisionIntegrityManifest) = manifest.valid

function _integrity_row(
    kind::Symbol;
    object_id = nothing,
    revision_id = nothing,
    schema = nothing,
    content_id = nothing,
    availability::Symbol,
    artifact = nothing,
    verified_level::Symbol = :none,
    bytes_checked::Integer = 0,
    diagnostics = DiagnosticMessage[],
)
    kind in INTEGRITY_DEPENDENCY_KINDS || throw(ArgumentError(
        "integrity dependency kind must be one of $INTEGRITY_DEPENDENCY_KINDS",
    ))
    availability in INTEGRITY_AVAILABILITY || throw(ArgumentError(
        "integrity availability must be one of $INTEGRITY_AVAILABILITY",
    ))
    verified_level in EXTERNAL_VERIFIED_LEVELS || throw(ArgumentError(
        "verified level must be one of $EXTERNAL_VERIFIED_LEVELS",
    ))
    return IntegrityDependencyRow(
        kind,
        object_id,
        revision_id,
        schema,
        content_id,
        availability,
        artifact,
        verified_level,
        Int64(bytes_checked),
        DiagnosticMessage[diagnostics...],
    )
end

function _integrity_entry_sort_key(entry::ManifestEntry)
    return (
        entry.object_id.value,
        entry.revision_id === nothing ? "" : entry.revision_id.value,
        String(entry.availability),
    )
end

function _integrity_schema_key(schema::SchemaRef)
    return (String(schema.namespace_id), schema.schema_id, schema.version)
end

function _integrity_row_sort_key(row::IntegrityDependencyRow)
    rank = row.kind === :object ? 1 : row.kind === :schema ? 2 : 3
    schema_key = row.schema === nothing ? ("", "", "") : _integrity_schema_key(row.schema)
    return (
        rank,
        row.object_id === nothing ? "" : row.object_id.value,
        row.revision_id === nothing ? "" : row.revision_id.value,
        schema_key...,
    )
end

function _append_integrity_diagnostics!(all, local_diagnostics)
    append!(all, local_diagnostics)
    return all
end

function _external_integrity_records(records)
    return _typed_vector(ExternalIntegrityRecord, records, "external integrity records")
end

function _match_external_integrity(records, entry::ManifestEntry)
    matches = ExternalIntegrityRecord[
        record for record in records if record.object_id == entry.object_id
    ]
    isempty(matches) && return nothing, :missing
    if entry.content_id !== nothing
        exact = ExternalIntegrityRecord[
            record for record in matches if record.content_id == entry.content_id
        ]
        length(exact) == 1 && return exact[1], :exact
        length(exact) > 1 && return nothing, :ambiguous
    end
    length(matches) == 1 && return matches[1], :object_only
    return nothing, :ambiguous
end

function _schema_identity_diagnostics(entry::ManifestEntry, definition::SchemaDefinition)
    diagnostics = DiagnosticMessage[]
    object = entry.object
    object === nothing && return diagnostics
    object_uuid = object.namespace.package_uuid
    schema_uuid = definition.namespace.package_uuid
    if !isempty(schema_uuid) && isempty(object_uuid)
        push!(diagnostics, error_diagnostic(
            :namespace_identity_missing,
            "object namespace :$(object.namespace.id) omits package UUID required by schema $(schema_kind(definition.schema))";
            object_id = object.object_id.value,
            schema_kind = schema_kind(definition.schema),
            registered_uuid = schema_uuid,
        ))
    elseif !isempty(schema_uuid) && !isempty(object_uuid) && schema_uuid != object_uuid
        push!(diagnostics, error_diagnostic(
            :namespace_identity_conflict,
            "object namespace :$(object.namespace.id) UUID $object_uuid does not match schema UUID $schema_uuid";
            object_id = object.object_id.value,
            schema_kind = schema_kind(definition.schema),
            package_uuid = object_uuid,
            registered_uuid = schema_uuid,
        ))
    end
    return diagnostics
end

function _object_integrity_row(entry::ManifestEntry, diagnostics)
    local_diags = DiagnosticMessage[]
    if entry.availability === :envelope_only && entry.content_id === nothing
        push!(local_diags, error_diagnostic(
            :missing_content_identity,
            "archived object $(entry.object_id.value) has no ContentId for integrity verification";
            object_id = entry.object_id.value,
            revision_id = entry.revision_id === nothing ? nothing : entry.revision_id.value,
        ))
    end
    _append_integrity_diagnostics!(diagnostics, local_diags)
    return _integrity_row(
        :object;
        object_id = entry.object_id,
        revision_id = entry.revision_id,
        schema = entry.object === nothing ? nothing : entry.object.schema,
        content_id = entry.content_id,
        availability = entry.availability,
        artifact = entry.artifact,
        diagnostics = local_diags,
    )
end

function _external_integrity_row(entry::ManifestEntry, records, requested, diagnostics)
    local_diags = DiagnosticMessage[]
    record, match = _match_external_integrity(records, entry)
    content_id = entry.content_id
    artifact = entry.artifact
    verified = :none
    checked = Int64(0)

    if record === nothing
        code = match === :ambiguous ? :external_integrity_ambiguous : :external_integrity_record_missing
        message = match === :ambiguous ?
            "multiple external integrity records match object $(entry.object_id.value)" :
            "no external integrity record is available for object $(entry.object_id.value)"
        push!(local_diags, error_diagnostic(
            code,
            message;
            object_id = entry.object_id.value,
        ))
    else
        artifact = record.artifact
        content_id === nothing && (content_id = record.content_id)
        if entry.content_id !== nothing && entry.content_id != record.content_id
            push!(local_diags, error_diagnostic(
                :external_content_identity_mismatch,
                "declared external ContentId does not match the captured integrity record";
                object_id = entry.object_id.value,
                declared_content_id = entry.content_id.value,
                record_content_id = record.content_id.value,
            ))
        else
            record_report = validate(record)
            append!(local_diags, record_report.diagnostics)
            if isvalid(record_report)
                result = verify_external(record; level = requested)
                verified = result.verified_level
                checked = result.bytes_checked
                append!(local_diags, result.diagnostics)
            end
        end
    end

    if content_id === nothing
        push!(local_diags, error_diagnostic(
            :missing_content_identity,
            "external object $(entry.object_id.value) has no expected ContentId";
            object_id = entry.object_id.value,
        ))
    end

    _append_integrity_diagnostics!(diagnostics, local_diags)
    return _integrity_row(
        :external;
        object_id = entry.object_id,
        revision_id = entry.revision_id,
        content_id = content_id,
        availability = :external_required,
        artifact = artifact,
        verified_level = verified,
        bytes_checked = checked,
        diagnostics = local_diags,
    )
end

function _selected_schema_entries(entries)
    selected = Dict{Tuple{String,String,String},Vector{ManifestEntry}}()
    refs = Dict{Tuple{String,String,String},SchemaRef}()
    for entry in entries
        entry.object === nothing && continue
        ref = entry.object.schema
        key = _integrity_schema_key(ref)
        push!(get!(selected, key, ManifestEntry[]), entry)
        refs[key] = ref
    end
    return selected, refs
end

function _selected_schema_definition(ref::SchemaRef, schemas::SchemaRegistry, diagnostics)
    matches = SchemaDefinition[
        definition for definition in schemas.entries if definition.schema == ref
    ]
    isempty(matches) && return nothing, :missing
    if length(matches) > 1
        push!(diagnostics, error_diagnostic(
            :duplicate_schema_identity,
            "embedded registry contains multiple definitions for schema $(schema_kind(ref)) version $(ref.version)";
            schema_kind = schema_kind(ref),
            version = ref.version,
            definitions = length(matches),
        ))
        return nothing, :ambiguous
    end
    return only(matches), :exact
end

function _schema_integrity_rows(entries, schemas::SchemaRegistry, diagnostics)
    selected, refs = _selected_schema_entries(entries)
    rows = IntegrityDependencyRow[]
    for key in sort!(collect(keys(refs)))
        ref = refs[key]
        local_diags = DiagnosticMessage[]
        definition, resolution = _selected_schema_definition(ref, schemas, local_diags)
        content_id = nothing
        availability = resolution === :ambiguous ? :ambiguous : :missing
        if resolution === :missing
            push!(local_diags, error_diagnostic(
                :missing_schema,
                "schema $(schema_kind(ref)) version $(ref.version) is not in the embedded registry";
                schema_kind = schema_kind(ref),
                version = ref.version,
            ))
        elseif resolution === :exact
            availability = :embedded_schema
            schema_report = validate(definition)
            append!(local_diags, schema_report.diagnostics)
            for entry in selected[key]
                append!(local_diags, _schema_identity_diagnostics(entry, definition))
            end
            try
                content_id = canonical_content_id(definition)
            catch err
                push!(local_diags, error_diagnostic(
                    :schema_content_hash_failed,
                    "failed to compute canonical content identity for schema $(schema_kind(ref))";
                    schema_kind = schema_kind(ref),
                    version = ref.version,
                    reason = sprint(showerror, err),
                ))
            end
        end
        _append_integrity_diagnostics!(diagnostics, local_diags)
        push!(rows, _integrity_row(
            :schema;
            schema = ref,
            content_id = content_id,
            availability = availability,
            verified_level = :none,
            diagnostics = local_diags,
        ))
    end
    return rows
end

"""
    integrity_manifest(manifest, schemas; external_integrity=(), level=:metadata)
        -> RevisionIntegrityManifest

Build a deterministic integrity report from an already selected
`RevisionManifest`. Only dependencies in that manifest are considered; unrelated
branches and history are never scanned.
"""
function integrity_manifest(
    manifest::RevisionManifest,
    schemas::SchemaRegistry;
    external_integrity = ExternalIntegrityRecord[],
    level::Symbol = :metadata,
)
    requested = _verification_level(level)
    records = _external_integrity_records(external_integrity)
    diagnostics = copy(manifest.diagnostics)
    rows = IntegrityDependencyRow[]
    entries = sort(copy(manifest.entries); by = _integrity_entry_sort_key)

    for entry in entries
        if entry.availability === :external_required
            push!(rows, _external_integrity_row(entry, records, requested, diagnostics))
        else
            push!(rows, _object_integrity_row(entry, diagnostics))
        end
    end
    append!(rows, _schema_integrity_rows(entries, schemas, diagnostics))
    sort!(rows; by = _integrity_row_sort_key)

    valid = !any(diagnostic -> diagnostic.severity === :error, diagnostics)
    return RevisionIntegrityManifest(
        manifest.revision.id,
        requested,
        valid,
        rows,
        diagnostics,
    )
end

"""
    integrity_manifest(graph, revision_id, schemas; externals=(),
                       external_integrity=(), level=:metadata)

Select the revision through the existing #33 visibility/closure rules and then
build its integrity manifest.
"""
function integrity_manifest(
    graph::ArchiveGraph,
    revision_id::RevisionId,
    schemas::SchemaRegistry;
    externals = ExternalRequirement[],
    external_integrity = ExternalIntegrityRecord[],
    level::Symbol = :metadata,
)
    selected = inspect(graph, revision_id; externals = externals)
    return integrity_manifest(
        selected,
        schemas;
        external_integrity = external_integrity,
        level = level,
    )
end

function validate(manifest::RevisionIntegrityManifest)
    return ValidationReport(
        :revision_integrity,
        manifest.valid,
        manifest.diagnostics,
        (;
            revision_id = manifest.revision_id.value,
            requested_level = manifest.requested_level,
            dependencies = length(manifest.dependencies),
        ),
    )
end

function report(manifest::RevisionIntegrityManifest)
    external_bytes = sum(
        row.bytes_checked for row in manifest.dependencies if row.kind === :external
    )
    return ObjectReport(
        :revision_integrity,
        "Revision $(manifest.revision_id.value) integrity $(manifest.valid ? "passed" : "failed") with $(length(manifest.dependencies)) dependency rows.",
        merge(to_namedtuple(manifest), (; external_bytes_checked = external_bytes)),
        manifest.diagnostics,
        ArtifactRef[
            row.artifact for row in manifest.dependencies
            if row.artifact !== nothing
        ],
    )
end

to_namedtuple(row::IntegrityDependencyRow) = (
    kind = row.kind,
    object_id = row.object_id === nothing ? nothing : row.object_id.value,
    revision_id = row.revision_id === nothing ? nothing : row.revision_id.value,
    schema = row.schema === nothing ? nothing : to_namedtuple(row.schema),
    content_id = row.content_id === nothing ? nothing : row.content_id.value,
    availability = row.availability,
    artifact = row.artifact === nothing ? nothing : to_namedtuple(row.artifact),
    verified_level = row.verified_level,
    bytes_checked = row.bytes_checked,
    diagnostics = Tuple(to_namedtuple.(row.diagnostics)),
)

to_namedtuple(manifest::RevisionIntegrityManifest) = (
    revision_id = manifest.revision_id.value,
    requested_level = manifest.requested_level,
    valid = manifest.valid,
    dependencies = Tuple(to_namedtuple.(manifest.dependencies)),
    diagnostics = Tuple(to_namedtuple.(manifest.diagnostics)),
)
