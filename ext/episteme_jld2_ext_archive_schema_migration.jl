# ---------------------------------------------------------------------------
# Materialize a semantic migration into a new AH5 archive (#140).
#
# The successor file is published only through `write_event_archive`. This
# module opens the source read-only and does not add an archive writer.
# ---------------------------------------------------------------------------

function _unpublished_migration(destination, revision_id, diagnostics)
    return Episteme._migration_archive_result(
        false,
        false,
        destination,
        revision_id,
        nothing,
        MigrationResult[],
        diagnostics,
    )
end

function Episteme.materialize_migration(
    destination::AbstractString,
    source::AbstractString,
    requests,
    migrations::SchemaMigrationRegistry;
    schemas::SchemaRegistry,
    revision_id::RevisionId,
    run_id::RunId,
    software_environment::Union{Nothing,SoftwareEnvironment} = nothing,
    software_environments::Union{Nothing,SoftwareEnvironmentRegistry} = nothing,
    namespaces::Union{Nothing,NamespaceRegistry} = nothing,
)
    dest = String(destination)
    src = String(source)
    ispath(dest) && throw(ArgumentError("archive already exists: $dest"))
    abspath(normpath(dest)) == abspath(normpath(src)) && throw(ArgumentError(
        "migration must not rewrite the source archive: $src",
    ))
    if !ispath(src)
        return _unpublished_migration(dest, revision_id, [error_diagnostic(
            :missing_archive,
            "source archive path does not exist: $src";
            path = src,
        )])
    end

    view = inspect_archive(src, ArchiveEventHistory)
    if !view.identified || !isvalid(view) || view.state === nothing
        diagnostics = DiagnosticMessage[view.diagnostics...]
        any(diagnostic -> diagnostic.code === :missing_state_history, diagnostics) ||
            push!(diagnostics, error_diagnostic(
                :missing_state_history,
                "source archive has no authoritative state history to migrate";
                path = src,
            ))
        return _unpublished_migration(dest, revision_id, diagnostics)
    end

    prepared = migrate_archive(
        reconstruct_graph(view),
        requests,
        migrations;
        schemas = schemas,
        revision_id = revision_id,
        run_id = run_id,
        software_environment = software_environment,
        software_environments = software_environments,
        namespaces = namespaces,
        externals = view.externals,
    )
    isvalid(prepared) || return Episteme._migration_archive_result(
        false,
        false,
        dest,
        prepared.revision_id,
        nothing,
        prepared.results,
        prepared.diagnostics,
    )

    registry = Episteme._migration_software_registry(
        software_environment, software_environments,
    )
    write_event_archive(
        dest,
        prepared.graph;
        namespaces = namespaces,
        schemas = schemas,
        externals = view.externals,
        software_environments = registry,
    )
    return Episteme._migration_archive_result(
        true,
        true,
        dest,
        prepared.revision_id,
        prepared.graph,
        prepared.results,
        prepared.diagnostics,
    )
end
