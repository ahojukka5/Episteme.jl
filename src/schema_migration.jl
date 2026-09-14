# ---------------------------------------------------------------------------
# In-memory semantic schema migration chains (#103 / parent #41)
#
# Episteme resolves and runs declared semantic migrations. Domain packages
# own payload meaning by extending `migrate_payload`. JLD2 representation
# upgrades and AH5 physical-layout rewrites are different axes and are
# refused in this slice.
# ---------------------------------------------------------------------------

const MIGRATION_AXES = (:semantic,)
const MIGRATION_PLAN_STATUSES = (
    :identity,
    :direct,
    :chain,
    :unsupported,
    :ambiguous,
)

"""
    SchemaMigrationStep(source, target; implementation_id, kwargs...)

One declared semantic transform from an exact source [`SchemaRef`](@ref)
to a different target. `implementation_id` names the domain-owned
`migrate_payload` method. `rewrite_payload=false` is metadata-only and may
reuse the source [`ContentId`](@ref) when the portable payload is unchanged.
"""
struct SchemaMigrationStep
    source::SchemaRef
    target::SchemaRef
    implementation_id::String
    axis::Symbol
    rewrite_payload::Bool
    required_package::String
end

function SchemaMigrationStep(
    source::SchemaRef,
    target::SchemaRef;
    implementation_id::AbstractString,
    axis::Symbol = :semantic,
    rewrite_payload::Bool = true,
    required_package::AbstractString = "",
)
    source == target && throw(ArgumentError(
        "schema migration source and target must differ",
    ))
    axis in MIGRATION_AXES || throw(ArgumentError(
        "schema migration axis :$axis is not supported (expected one of $MIGRATION_AXES); JLD2 Upgrade is not a semantic migration",
    ))
    impl = String(strip(implementation_id))
    isempty(impl) && throw(ArgumentError(
        "schema migration implementation_id must name a domain-owned migrator",
    ))
    return SchemaMigrationStep(
        source,
        target,
        impl,
        axis,
        rewrite_payload,
        String(strip(required_package)),
    )
end

function SchemaMigrationStep(
    ref::SchemaMigrationRef;
    axis::Symbol = :semantic,
    rewrite_payload::Bool = true,
    required_package::AbstractString = "",
)
    return SchemaMigrationStep(
        ref.source,
        ref.target;
        implementation_id = ref.implementation_id,
        axis = axis,
        rewrite_payload = rewrite_payload,
        required_package = required_package,
    )
end

"""
    SchemaMigrationRegistry(steps)
    SchemaMigrationRegistry(schemas::SchemaRegistry; kwargs...)

Directed graph of semantic migration steps. Keys are exact schema
namespace, id, and version; package SemVer is ignored.
"""
struct SchemaMigrationRegistry
    steps::Vector{SchemaMigrationStep}

    function SchemaMigrationRegistry(steps)
        registry = new(_typed_vector(SchemaMigrationStep, steps, "schema migration steps"))
        _require_unique_migration_edges(registry)
        return registry
    end
end

function SchemaMigrationRegistry(
    schemas::SchemaRegistry;
    rewrite_payload::Bool = true,
)
    steps = SchemaMigrationStep[]
    for entry in ordered_schemas(schemas)
        entry.migration === nothing && continue
        push!(
            steps,
            SchemaMigrationStep(
                entry.migration;
                rewrite_payload = rewrite_payload,
                required_package = entry.namespace.display_name,
            ),
        )
    end
    return SchemaMigrationRegistry(steps)
end

function _schema_ref_key(schema::SchemaRef)
    return (schema.namespace_id, schema.schema_id, schema.version)
end

function _require_unique_migration_edges(registry::SchemaMigrationRegistry)
    seen = Dict{Any,String}()
    for step in registry.steps
        key = (_schema_ref_key(step.source), _schema_ref_key(step.target))
        previous = get(seen, key, nothing)
        previous === nothing && (seen[key] = step.implementation_id; continue)
        previous == step.implementation_id && throw(ArgumentError(
            "duplicate schema migration $(schema_kind(step.source)) $(step.source.version) -> $(schema_kind(step.target)) $(step.target.version)",
        ))
        throw(ArgumentError(
            "ambiguous schema migrations $(schema_kind(step.source)) $(step.source.version) -> $(schema_kind(step.target)) $(step.target.version)",
        ))
    end
    return registry
end

function _migration_adjacency(registry::SchemaMigrationRegistry)
    adjacency = Dict{SchemaRef,Vector{SchemaMigrationStep}}()
    for step in registry.steps
        push!(get!(adjacency, step.source, SchemaMigrationStep[]), step)
    end
    return adjacency
end

"""
    MigrationPlan <: AbstractValidationReport

Dry-run of one source-to-target semantic migration. Invalid plans must not
be applied.
"""
struct MigrationPlan <: AbstractValidationReport
    source::SchemaRef
    target::SchemaRef
    valid::Bool
    status::Symbol
    steps::Vector{SchemaMigrationStep}
    rewrite_payload::Bool
    diagnostics::Vector{DiagnosticMessage}
end

Base.isvalid(plan::MigrationPlan) = plan.valid

"""
    MigrationResult <: AbstractValidationReport

In-memory application of a valid [`MigrationPlan`](@ref). The source
[`ArchiveObject`](@ref) is never mutated.
"""
struct MigrationResult <: AbstractValidationReport
    source_unchanged::Bool
    valid::Bool
    object::Union{Nothing,ArchiveObject}
    payload::Union{Nothing,NamedTuple}
    plan::MigrationPlan
    source_schema::SchemaRef
    target_schema::SchemaRef
    source_revision_id::RevisionId
    diagnostics::Vector{DiagnosticMessage}
end

Base.isvalid(result::MigrationResult) = result.valid

function _invalid_migration_plan(source, target, status, diagnostics)
    return MigrationPlan(
        source,
        target,
        false,
        status,
        SchemaMigrationStep[],
        false,
        diagnostics,
    )
end

"""
    plan_migration(source, target, migrations; schemas=nothing) -> MigrationPlan

Resolve a unique shortest semantic chain. Equal source and target is the
identity plan. Ambiguous shortest paths and missing chains fail closed.
"""
function plan_migration(
    source::SchemaRef,
    target::SchemaRef,
    migrations::SchemaMigrationRegistry;
    schemas = nothing,
)
    diagnostics = DiagnosticMessage[]
    if schemas !== nothing
        schemas isa SchemaRegistry || throw(ArgumentError(
            "schemas must be SchemaRegistry, got $(typeof(schemas))",
        ))
        for schema in (source, target)
            resolve_schema(schema, schemas) === nothing || continue
            push!(diagnostics, error_diagnostic(
                :missing_schema,
                "schema $(schema_kind(schema)) version $(schema.version) is not in the embedded registry";
                schema_kind = schema_kind(schema),
                version = schema.version,
            ))
        end
        target_def = resolve_schema(target, schemas)
        if target_def !== nothing && target_def.compatibility === :unsupported
            push!(diagnostics, error_diagnostic(
                :unsupported_schema,
                "schema $(schema_kind(target)) version $(target.version) is marked unsupported";
                schema_kind = schema_kind(target),
                version = target.version,
            ))
        end
        isempty(diagnostics) || return _invalid_migration_plan(
            source, target, :unsupported, diagnostics,
        )
    end

    if source == target
        return MigrationPlan(
            source,
            target,
            true,
            :identity,
            SchemaMigrationStep[],
            false,
            diagnostics,
        )
    end

    adjacency = _migration_adjacency(migrations)
    dist = Dict{SchemaRef,Int}(source => 0)
    parents = Dict{SchemaRef,Vector{SchemaMigrationStep}}()
    queue = SchemaRef[source]
    while !isempty(queue)
        node = popfirst!(queue)
        for step in get(adjacency, node, SchemaMigrationStep[])
            nxt = step.target
            nd = dist[node] + 1
            previous = get(dist, nxt, nothing)
            if previous === nothing
                dist[nxt] = nd
                parents[nxt] = SchemaMigrationStep[step]
                push!(queue, nxt)
            elseif previous == nd
                push!(parents[nxt], step)
            end
        end
    end

    if !haskey(dist, target)
        push!(diagnostics, error_diagnostic(
            :unsupported_migration,
            "no semantic migration chain from $(schema_kind(source)) $(source.version) to $(schema_kind(target)) $(target.version)";
            source_kind = schema_kind(source),
            source_version = source.version,
            target_kind = schema_kind(target),
            target_version = target.version,
        ))
        return _invalid_migration_plan(source, target, :unsupported, diagnostics)
    end

    steps = SchemaMigrationStep[]
    node = target
    while haskey(parents, node)
        incoming = parents[node]
        if length(incoming) != 1
            push!(diagnostics, error_diagnostic(
                :ambiguous_migration,
                "multiple shortest semantic migration chains from $(schema_kind(source)) $(source.version) to $(schema_kind(target)) $(target.version)";
                source_kind = schema_kind(source),
                source_version = source.version,
                target_kind = schema_kind(target),
                target_version = target.version,
            ))
            return _invalid_migration_plan(source, target, :ambiguous, diagnostics)
        end
        step = only(incoming)
        push!(steps, step)
        node = step.source
    end
    reverse!(steps)
    if node != source || (isempty(steps) && source != target)
        push!(diagnostics, error_diagnostic(
            :unsupported_migration,
            "semantic migration reconstruction did not reach $(schema_kind(source)) $(source.version)";
            source_kind = schema_kind(source),
            source_version = source.version,
        ))
        return _invalid_migration_plan(source, target, :unsupported, diagnostics)
    end

    status = length(steps) == 1 ? :direct : :chain
    rewrite = any(step -> step.rewrite_payload, steps)
    return MigrationPlan(source, target, true, status, steps, rewrite, diagnostics)
end

"""
    migrate_payload(implementation, payload, step) -> NamedTuple

Domain extension point. Episteme does not know scientific meaning and
must not invent required target fields. Missing methods return `missing`.
"""
function migrate_payload(::Val, payload, ::SchemaMigrationStep)
    return missing
end

function _implementation_val(step::SchemaMigrationStep)
    return Val{Symbol(step.implementation_id)}()
end

function _failed_migration(object, plan, diagnostics)
    return MigrationResult(
        true,
        false,
        nothing,
        nothing,
        plan,
        object.schema,
        plan.target,
        object.revision_id,
        diagnostics,
    )
end

function _copy_object(
    object::ArchiveObject;
    revision_id::RevisionId,
    schema::SchemaRef,
    content_id,
)
    return ArchiveObject(
        object.object_id,
        revision_id;
        content_id = content_id,
        run_id = object.run_id,
        namespace = object.namespace,
        kind = schema_kind(schema),
        schema = schema,
        provenance = object.provenance,
        references = copy(object.references),
    )
end

"""
    migrate_object(object, payload, target, migrations; schemas, revision_id)
        -> MigrationResult

Apply a planned semantic chain to a portable NamedTuple payload. The source
envelope is not mutated. Metadata-only chains reuse `object.content_id`;
payload rewrites mint a new canonical identity.
"""
function migrate_object(
    object::ArchiveObject,
    payload,
    target::SchemaRef,
    migrations::SchemaMigrationRegistry;
    schemas::SchemaRegistry,
    revision_id::RevisionId,
)
    plan = plan_migration(object.schema, target, migrations; schemas = schemas)
    diagnostics = copy(plan.diagnostics)
    payload isa NamedTuple || (push!(diagnostics, error_diagnostic(
        :nonportable_payload,
        "semantic migration requires a portable NamedTuple payload";
        object_id = object.object_id.value,
        schema_kind = schema_kind(object.schema),
    )); return _failed_migration(object, plan, diagnostics))

    isvalid(plan) || return _failed_migration(object, plan, diagnostics)
    revision_id == object.revision_id && (push!(diagnostics, error_diagnostic(
        :migration_revision_conflict,
        "migrated object must be materialized in a new revision, not rewritten in $(object.revision_id.value)";
        object_id = object.object_id.value,
        revision_id = object.revision_id.value,
    )); return _failed_migration(object, plan, diagnostics))

    current = payload
    current_schema = object.schema
    for step in plan.steps
        source_def = resolve_schema(step.source, schemas)
        source_def === nothing && (push!(diagnostics, error_diagnostic(
            :missing_schema,
            "migration step source $(schema_kind(step.source)) $(step.source.version) is not embedded";
            schema_kind = schema_kind(step.source),
            version = step.source.version,
        )); return _failed_migration(object, plan, diagnostics))
        source_report = validate(current, source_def)
        append!(diagnostics, source_report.diagnostics)
        isvalid(source_report) || return _failed_migration(object, plan, diagnostics)

        next_payload = migrate_payload(_implementation_val(step), current, step)
        if next_payload === missing
            package = isempty(step.required_package) ? step.implementation_id :
                step.required_package
            push!(diagnostics, error_diagnostic(
                :migration_implementation_missing,
                "domain migrator $(step.implementation_id) is not loaded; required capability $(package)";
                implementation_id = step.implementation_id,
                required_package = package,
                source_kind = schema_kind(step.source),
                target_kind = schema_kind(step.target),
            ))
            return _failed_migration(object, plan, diagnostics)
        end
        next_payload isa NamedTuple || (push!(diagnostics, error_diagnostic(
            :nonportable_payload,
            "domain migrator $(step.implementation_id) did not return a portable NamedTuple";
            implementation_id = step.implementation_id,
        )); return _failed_migration(object, plan, diagnostics))

        if !step.rewrite_payload && next_payload != current
            push!(diagnostics, error_diagnostic(
                :migration_rewrote_metadata_only,
                "metadata-only migrator $(step.implementation_id) changed portable payload bytes";
                implementation_id = step.implementation_id,
            ))
            return _failed_migration(object, plan, diagnostics)
        end
        if step.rewrite_payload && next_payload == current
            # Allowed: a declared rewrite may keep values while changing schema
            # identity. Canonical content identity is still recomputed below.
        end

        target_def = resolve_schema(step.target, schemas)
        target_def === nothing && (push!(diagnostics, error_diagnostic(
            :missing_schema,
            "migration step target $(schema_kind(step.target)) $(step.target.version) is not embedded";
            schema_kind = schema_kind(step.target),
            version = step.target.version,
        )); return _failed_migration(object, plan, diagnostics))
        target_report = validate(next_payload, target_def)
        append!(diagnostics, target_report.diagnostics)
        isvalid(target_report) || return _failed_migration(object, plan, diagnostics)

        current = next_payload
        current_schema = step.target
    end

    content_id = object.content_id
    if plan.rewrite_payload
        try
            content_id = canonical_content_id(current)
        catch err
            push!(diagnostics, error_diagnostic(
                :content_hash_failed,
                "failed to compute canonical content identity for migrated payload";
                reason = sprint(showerror, err),
            ))
            return _failed_migration(object, plan, diagnostics)
        end
    elseif current != payload
        push!(diagnostics, error_diagnostic(
            :migration_rewrote_metadata_only,
            "metadata-only migration chain changed portable payload bytes",
        ))
        return _failed_migration(object, plan, diagnostics)
    end

    migrated = _copy_object(
        object;
        revision_id = revision_id,
        schema = current_schema,
        content_id = content_id,
    )
    return MigrationResult(
        true,
        true,
        migrated,
        current,
        plan,
        object.schema,
        current_schema,
        object.revision_id,
        diagnostics,
    )
end

function validate(plan::MigrationPlan)
    return ValidationReport(
        :schema_migration_plan,
        plan.valid,
        plan.diagnostics,
        (;
            source = to_namedtuple(plan.source),
            target = to_namedtuple(plan.target),
            status = plan.status,
            steps = length(plan.steps),
            rewrite_payload = plan.rewrite_payload,
        ),
    )
end

function validate(result::MigrationResult)
    return ValidationReport(
        :schema_migration,
        result.valid,
        result.diagnostics,
        (;
            source_unchanged = result.source_unchanged,
            source_revision_id = result.source_revision_id.value,
            rewrite_payload = result.plan.rewrite_payload,
        ),
    )
end

function report(plan::MigrationPlan)
    return ObjectReport(
        :schema_migration_plan,
        plan.valid ?
            "Semantic migration plan $(plan.status) with $(length(plan.steps)) step(s)." :
            "Semantic migration plan failed ($(plan.status)).",
        to_namedtuple(plan),
        plan.diagnostics,
        ArtifactRef[],
    )
end

function report(result::MigrationResult)
    return ObjectReport(
        :schema_migration,
        result.valid ?
            "Migrated $(schema_kind(result.source_schema)) to $(schema_kind(result.target_schema)) without mutating the source." :
            "Semantic migration failed before writing an output object.",
        to_namedtuple(result),
        result.diagnostics,
        ArtifactRef[],
    )
end

function readiness(plan::MigrationPlan, target::PipelineTarget)
    target.name === :migrate || return ReadinessReport(
        :schema_migration_plan,
        target,
        false,
        [error_diagnostic(
            :unsupported_target,
            "migration plan readiness target :$(target.name) is not :migrate";
            target = target.name,
        )],
        (;),
    )
    return ReadinessReport(
        :schema_migration_plan,
        target,
        plan.valid,
        copy(plan.diagnostics),
        (; status = plan.status, steps = length(plan.steps)),
    )
end

to_namedtuple(step::SchemaMigrationStep) = (
    source = to_namedtuple(step.source),
    target = to_namedtuple(step.target),
    implementation_id = step.implementation_id,
    axis = step.axis,
    rewrite_payload = step.rewrite_payload,
    required_package = step.required_package,
)

to_namedtuple(registry::SchemaMigrationRegistry) = (
    steps = Tuple(to_namedtuple.(registry.steps)),
)

to_namedtuple(plan::MigrationPlan) = (
    source = to_namedtuple(plan.source),
    target = to_namedtuple(plan.target),
    valid = plan.valid,
    status = plan.status,
    steps = Tuple(to_namedtuple.(plan.steps)),
    rewrite_payload = plan.rewrite_payload,
    diagnostics = Tuple(to_namedtuple.(plan.diagnostics)),
)

to_namedtuple(result::MigrationResult) = (
    source_unchanged = result.source_unchanged,
    valid = result.valid,
    object = result.object === nothing ? nothing : to_namedtuple(result.object),
    payload = result.payload,
    plan = to_namedtuple(result.plan),
    source_schema = to_namedtuple(result.source_schema),
    target_schema = to_namedtuple(result.target_schema),
    source_revision_id = result.source_revision_id.value,
    diagnostics = Tuple(to_namedtuple.(result.diagnostics)),
)
