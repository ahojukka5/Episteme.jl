# ---------------------------------------------------------------------------
# Publish a semantic migration into a new archive graph (#140 / parent #41).
#
# `migrate_object` remains the payload runner. This file only assembles the
# successor graph. File creation stays in EpistemeJLD2Ext and calls
# `write_event_archive`; there is no second AH5 writer here.
# ---------------------------------------------------------------------------

"""
    MigrationRequest(object_id, revision_id, target, payload)

One object version to migrate. `payload` is the portable NamedTuple the
domain migrator receives. AH5 does not store that payload.
"""
struct MigrationRequest
    object_id::ObjectId
    revision_id::RevisionId
    target::SchemaRef
    payload::NamedTuple
end

"""
    MigrationArchiveResult <: AbstractValidationReport

Successor graph for a semantic migration. `published` is true only after a
new archive file has been created. Invalid results carry no graph, so a
caller cannot write a partial migration by mistake.
"""
struct MigrationArchiveResult <: AbstractValidationReport
    valid::Bool
    published::Bool
    destination::String
    revision_id::RevisionId
    graph::Union{Nothing,ArchiveGraph}
    results::Vector{MigrationResult}
    diagnostics::Vector{DiagnosticMessage}
end

Base.isvalid(result::MigrationArchiveResult) = result.valid

function _migration_archive_result(
    valid::Bool,
    published::Bool,
    destination::AbstractString,
    revision_id::RevisionId,
    graph::Union{Nothing,ArchiveGraph},
    results,
    diagnostics,
)
    published && !valid && throw(ArgumentError(
        "invalid schema migration cannot be published",
    ))
    valid && graph === nothing && throw(ArgumentError(
        "valid schema migration archive is missing its graph",
    ))
    !valid && graph !== nothing && throw(ArgumentError(
        "invalid schema migration must not carry a successor graph",
    ))
    published && isempty(strip(destination)) && throw(ArgumentError(
        "published schema migration requires a destination path",
    ))
    return MigrationArchiveResult(
        valid,
        published,
        String(destination),
        revision_id,
        graph,
        _typed_vector(MigrationResult, results, "migration results"),
        DiagnosticMessage[diagnostics...],
    )
end

function _failed_migration_archive(revision_id, results, diagnostics; destination = "")
    return _migration_archive_result(
        false,
        false,
        destination,
        revision_id,
        nothing,
        results,
        diagnostics,
    )
end

function _migration_software_registry(software_environment, software_environments)
    if software_environments !== nothing
        software_environments isa SoftwareEnvironmentRegistry || throw(ArgumentError(
            "software_environments must be SoftwareEnvironmentRegistry or nothing, got $(typeof(software_environments))",
        ))
        if software_environment !== nothing &&
                find_software_environment(software_environments, software_environment.id) === nothing
            throw(ArgumentError(
                "migration software environment $(software_environment.id.value) is not in software_environments",
            ))
        end
        return software_environments
    end
    software_environment === nothing && return nothing
    return SoftwareEnvironmentRegistry((software_environment,))
end

function _migration_object(migrated::ArchiveObject, run_id::RunId, software)
    provenance = migrated.provenance
    if software !== nothing
        provenance = ProvenanceRefs(;
            software_environment = software.id,
            execution_context = migrated.provenance.execution_context,
        )
    end
    return ArchiveObject(
        migrated.object_id,
        migrated.revision_id;
        content_id = migrated.content_id,
        run_id = run_id,
        namespace = migrated.namespace,
        kind = migrated.kind,
        schema = migrated.schema,
        provenance = provenance,
        references = migrated.references,
    )
end

function _migration_event_payload(source::ArchiveObject, result::MigrationResult, software)
    source_content = source.content_id
    content = result.object.content_id
    return (
        axis = "semantic",
        status = String(result.plan.status),
        object_id = source.object_id.value,
        implementation_ids = String[step.implementation_id for step in result.plan.steps],
        source_namespace = String(result.source_schema.namespace_id),
        source_schema_id = result.source_schema.schema_id,
        source_version = result.source_schema.version,
        target_namespace = String(result.target_schema.namespace_id),
        target_schema_id = result.target_schema.schema_id,
        target_version = result.target_schema.version,
        source_revision_id = result.source_revision_id.value,
        source_content_id = source_content === nothing ? "" : source_content.value,
        content_id = content === nothing ? "" : content.value,
        rewrite_payload = result.plan.rewrite_payload,
        software_environment = software === nothing ? "" : software.id.value,
        diagnostic_codes = String[String(item.code) for item in result.diagnostics],
        diagnostic_severities = String[String(item.severity) for item in result.diagnostics],
        diagnostic_messages = String[item.message for item in result.diagnostics],
    )
end

function _migration_parents(results)
    parents = RevisionId[]
    for result in results
        parent = result.source_revision_id
        parent in parents || push!(parents, parent)
    end
    return parents
end

function _migrated_heads(heads, parents, revision_id)
    moved = length(parents) == 1 ? only(parents) : nothing
    updated = WorkflowHead[]
    for head in heads
        if moved !== nothing && head.revision_id == moved
            push!(updated, WorkflowHead(head.id, head.name, revision_id))
        else
            push!(updated, head)
        end
    end
    return updated
end

function _missing_software_diagnostics(graph, registry)
    diagnostics = DiagnosticMessage[]
    registry === nothing && return diagnostics
    for id in ArchiveProvenanceSummary(graph).software_environments
        find_software_environment(registry, SoftwareEnvironmentId(id)) === nothing || continue
        push!(diagnostics, error_diagnostic(
            :missing_software_environment,
            "migrated archive references software environment $id with no record";
            software_environment = id,
        ))
    end
    return diagnostics
end

function _publishable_migration_diagnostics(graph, schemas, namespaces, externals)
    diagnostics = DiagnosticMessage[]
    state = _state_history_from_graph(graph)
    namespace_listings = list_namespaces(graph, namespaces)
    schema_listings = list_schemas(schemas)
    runs = RunRecord[ordered_runs(graph)...]
    append!(diagnostics, _validate_state_history(
        state;
        externals = externals,
        namespaces = namespace_listings,
        schemas = schema_listings,
    ))
    append!(diagnostics, _validate_run_history(
        state,
        runs;
        externals = externals,
        namespaces = namespace_listings,
        schemas = schema_listings,
    ))
    history = ArchiveEventHistory(
        EventRecord[graph.events...];
        writes = graph.writes,
        log_streams = graph.log_streams,
    )
    append!(diagnostics, _validate_event_history(state, runs, history; externals = externals))
    report = namespaces === nothing ?
        validate(graph, schemas) :
        validate(graph, schemas, namespaces)
    append!(diagnostics, report.diagnostics)
    return diagnostics
end

function _has_migration_error(diagnostics)
    return any(diagnostic -> diagnostic.severity === :error, diagnostics)
end

"""
    migrate_archive(graph, requests, migrations; schemas, revision_id, run_id,
                    software_environment=nothing, kwargs...) -> MigrationArchiveResult

Apply `requests` with [`migrate_object`](@ref) and return a new graph.
The source graph is not mutated and no file is written.

The successor keeps every source object and revision, appends migrated
objects at `revision_id`, and sets that revision's parents to the source
revisions. A single parent also moves heads that pointed at it. Metadata-only
chains reuse `ContentId`; payload rewrites keep the canonical id from
`migrate_object`. The migration run records software identity when
`software_environment` is given, and one event per object records the
implementation ids, schema identities, content ids, and diagnostics.
"""
function migrate_archive(
    graph::ArchiveGraph,
    requests,
    migrations::SchemaMigrationRegistry;
    schemas::SchemaRegistry,
    revision_id::RevisionId,
    run_id::RunId,
    software_environment::Union{Nothing,SoftwareEnvironment} = nothing,
    software_environments::Union{Nothing,SoftwareEnvironmentRegistry} = nothing,
    namespaces::Union{Nothing,NamespaceRegistry} = nothing,
    externals = ExternalRequirement[],
)
    registry = _migration_software_registry(software_environment, software_environments)
    parsed = _typed_vector(MigrationRequest, requests, "migration requests")
    diagnostics = DiagnosticMessage[]
    results = MigrationResult[]
    if isempty(parsed)
        push!(diagnostics, error_diagnostic(
            :empty_migration,
            "schema migration requires at least one object request",
        ))
        return _failed_migration_archive(revision_id, results, diagnostics)
    end
    if find_revision(graph, revision_id) !== nothing
        push!(diagnostics, error_diagnostic(
            :revision_exists,
            "migration revision $(revision_id.value) already exists in the source archive";
            revision_id = revision_id.value,
        ))
        return _failed_migration_archive(revision_id, results, diagnostics)
    end
    if find_run(graph, run_id) !== nothing
        push!(diagnostics, error_diagnostic(
            :duplicate_run,
            "migration run $(run_id.value) already exists in the source archive";
            run_id = run_id.value,
        ))
        return _failed_migration_archive(revision_id, results, diagnostics)
    end

    seen = Set{Tuple{String,String}}()
    sources = ArchiveObject[]
    for request in parsed
        key = (request.object_id.value, request.revision_id.value)
        if key in seen
            push!(diagnostics, error_diagnostic(
                :duplicate_migration_request,
                "object $(request.object_id.value) @ $(request.revision_id.value) is requested more than once";
                object_id = request.object_id.value,
                revision_id = request.revision_id.value,
            ))
            continue
        end
        push!(seen, key)
        source = find_object(graph, request.object_id, request.revision_id)
        if source === nothing
            push!(diagnostics, error_diagnostic(
                :missing_migration_object,
                "archive has no object $(request.object_id.value) @ $(request.revision_id.value)";
                object_id = request.object_id.value,
                revision_id = request.revision_id.value,
            ))
            continue
        end
        if find_revision(graph, source.revision_id) === nothing
            push!(diagnostics, error_diagnostic(
                :missing_revision_record,
                "object $(source.object_id.value) names revision $(source.revision_id.value) with no revision record";
                object_id = source.object_id.value,
                revision_id = source.revision_id.value,
            ))
            continue
        end
        if source.run_id !== nothing && find_run(graph, source.run_id) === nothing
            push!(diagnostics, error_diagnostic(
                :missing_object_run,
                "object $(source.object_id.value) names run $(source.run_id.value), which is not in the loaded archive";
                object_id = source.object_id.value,
                revision_id = source.revision_id.value,
                run_id = source.run_id.value,
            ))
            continue
        end
        result = migrate_object(
            source,
            request.payload,
            request.target,
            migrations;
            schemas = schemas,
            revision_id = revision_id,
        )
        push!(results, result)
        push!(sources, source)
        append!(diagnostics, result.diagnostics)
    end
    if length(results) != length(parsed) || any(!isvalid, results) ||
            _has_migration_error(diagnostics)
        return _failed_migration_archive(revision_id, results, diagnostics)
    end

    if software_environment === nothing
        push!(diagnostics, warning_diagnostic(
            :software_provenance_unknown,
            "schema migration did not record a software environment";
            run_id = run_id.value,
        ))
    end

    activities = ActivityRecord[]
    events = EventRecord[graph.events...]
    objects = ArchiveObject[graph.objects...]
    for (index, result) in enumerate(results)
        source = sources[index]
        migrated = _migration_object(result.object, run_id, software_environment)
        activity_id = ActivityId(string(run_id.value, "/", index))
        push!(activities, ActivityRecord(
            activity_id,
            run_id,
            :schema_migration;
            used = [ArchiveReference(
                :source, source.object_id; revision_id = source.revision_id,
            )],
            generated = [ArchiveReference(
                :migrated, migrated.object_id; revision_id = migrated.revision_id,
            )],
            reuse = result.plan.rewrite_payload ? :computed : :reused,
        ))
        push!(events, EventRecord(
            :schema_migration,
            run_id;
            activity_id = activity_id,
            sequence = index,
            source = "schema-migration",
            severity = :info,
            message = "migrated $(schema_kind(result.source_schema)) $(result.source_schema.version) to $(schema_kind(result.target_schema)) $(result.target_schema.version)",
            scope = :migration,
            revision_id = revision_id,
            object_refs = [
                ObjectRef(source.object_id, source.revision_id),
                ObjectRef(migrated.object_id, migrated.revision_id),
            ],
            retention = :forensic,
            payload = _migration_event_payload(source, result, software_environment),
        ))
        push!(objects, migrated)
    end

    parents = _migration_parents(results)
    run = RunRecord(
        run_id;
        status = :completed,
        revision_id = revision_id,
        software_environment = software_environment === nothing ? nothing : software_environment.id,
        activities = activities,
    )
    revisions = RevisionRecord[graph.revisions...]
    push!(revisions, RevisionRecord(revision_id; parents = parents, run_id = run_id))
    runs = RunRecord[graph.runs...]
    push!(runs, run)
    successor = ArchiveGraph(
        objects;
        heads = _migrated_heads(graph.heads, parents, revision_id),
        revisions = revisions,
        runs = runs,
        events = events,
        writes = graph.writes,
        log_streams = graph.log_streams,
    )
    append!(diagnostics, _missing_software_diagnostics(successor, registry))
    append!(diagnostics, _publishable_migration_diagnostics(
        successor, schemas, namespaces, externals,
    ))
    if _has_migration_error(diagnostics)
        return _failed_migration_archive(revision_id, results, diagnostics)
    end
    return _migration_archive_result(
        true,
        false,
        "",
        revision_id,
        successor,
        results,
        diagnostics,
    )
end

function validate(result::MigrationArchiveResult)
    return ValidationReport(
        :schema_migration_archive,
        result.valid,
        result.diagnostics,
        (;
            published = result.published,
            destination = result.destination,
            revision_id = result.revision_id.value,
            results = length(result.results),
        ),
    )
end

function report(result::MigrationArchiveResult)
    summary = result.published ?
        "Published semantic migration at $(result.revision_id.value) to $(result.destination)." :
        result.valid ?
            "Prepared semantic migration at $(result.revision_id.value); no archive written." :
            "Semantic migration failed before an archive was published."
    return ObjectReport(
        :schema_migration_archive,
        summary,
        to_namedtuple(result),
        result.diagnostics,
        ArtifactRef[],
    )
end

function to_namedtuple(request::MigrationRequest)
    return (
        object_id = request.object_id.value,
        revision_id = request.revision_id.value,
        target = to_namedtuple(request.target),
        payload = request.payload,
    )
end

function to_namedtuple(result::MigrationArchiveResult)
    graph = result.graph
    return (
        valid = result.valid,
        published = result.published,
        destination = result.destination,
        revision_id = result.revision_id.value,
        objects = graph === nothing ? 0 : length(graph.objects),
        revisions = graph === nothing ? 0 : length(graph.revisions),
        results = Tuple(to_namedtuple(item) for item in result.results),
        diagnostics = Tuple(to_namedtuple(item) for item in result.diagnostics),
    )
end
