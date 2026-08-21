# ---------------------------------------------------------------------------
# Embedded payload schemas and compatibility metadata (#39)
#
# Logical schema definitions that an archive must carry so a reader can
# inspect structure without the owning domain package. Physical `/schemas`
# storage is issue #40. Migration *execution* is issue #41.
# JLD2 `/_types` is Julia representation metadata, not schema identity.
# ---------------------------------------------------------------------------

const SCHEMA_CARDINALITIES = (:one, :many)

"""
    SchemaMigrationRef(source, target; implementation_id="")

Machine-readable pointer from one exact [`SchemaRef`](@ref) to another.
The implementation string identifies a domain-owned migrator; Episteme
does not run it here (#41).
"""
struct SchemaMigrationRef
    source::SchemaRef
    target::SchemaRef
    implementation_id::String
end

function SchemaMigrationRef(
    source::SchemaRef,
    target::SchemaRef;
    implementation_id::AbstractString = "",
)
    source == target && throw(ArgumentError(
        "schema migration source and target must differ",
    ))
    return SchemaMigrationRef(source, target, String(strip(implementation_id)))
end

"""
    SchemaField(name, element; rank=0, shape=(), required=true,
                cardinality=:one, support="", location="",
                reference_target=nothing, rules=(), documentation="")

One portable payload-schema field. This is logical content, not an HDF5
dataset descriptor: chunking, compression, and physical paths are #40.

`rank == 0` is a scalar. `cardinality = :many` means a list of that
element. `reference_target` names a package-qualified kind when the field
is a logical object reference.
"""
struct SchemaField
    name::Symbol
    element::LogicalType
    rank::Int
    shape::Tuple{Vararg{Union{Nothing,Int}}}
    required::Bool
    cardinality::Symbol
    support::String
    location::String
    reference_target::Union{Nothing,Symbol}
    rules::Tuple{Vararg{ValidationRule}}
    documentation::String
end

function SchemaField(
    name::Symbol,
    element::LogicalType;
    rank::Integer = 0,
    shape = (),
    required::Bool = true,
    cardinality::Symbol = :one,
    support::AbstractString = "",
    location::AbstractString = "",
    reference_target = nothing,
    rules = (),
    documentation::AbstractString = "",
)
    rank < 0 && throw(ArgumentError("schema field rank must be non-negative"))
    cardinality in SCHEMA_CARDINALITIES || throw(ArgumentError(
        "unknown schema cardinality :$cardinality (expected one of $SCHEMA_CARDINALITIES)",
    ))
    dims = _shape_tuple(shape)
    !isempty(dims) && length(dims) != Int(rank) && throw(ArgumentError(
        "shape length $(length(dims)) does not match rank $rank",
    ))
    target = _optional_symbol(reference_target)
    rule_values = _validation_rule_tuple(rules)
    return SchemaField(
        name,
        element,
        Int(rank),
        dims,
        required,
        cardinality,
        String(support),
        String(location),
        target,
        rule_values,
        String(documentation),
    )
end

function SchemaField(spec::LogicalArraySpec; kwargs...)
    return SchemaField(spec.name, spec.element; rank = spec.rank, shape = spec.shape, kwargs...)
end

function _optional_symbol(value)
    value === nothing && return nothing
    value isa Symbol || throw(ArgumentError(
        "reference_target must be a Symbol or nothing, got $(typeof(value))",
    ))
    return value
end

function _validation_rule_tuple(rules)
    result = ValidationRule[]
    for rule in rules
        rule isa ValidationRule || throw(ArgumentError(
            "schema field rules must be ValidationRule values",
        ))
        push!(result, rule)
    end
    return Tuple(result)
end

function _optional_schema_ref(value)
    value === nothing && return nothing
    value isa SchemaRef || throw(ArgumentError(
        "expected SchemaRef or nothing, got $(typeof(value))",
    ))
    return value
end

function _optional_migration(value)
    value === nothing && return nothing
    value isa SchemaMigrationRef || throw(ArgumentError(
        "expected SchemaMigrationRef or nothing, got $(typeof(value))",
    ))
    return value
end

function _optional_node_schema(value)
    value === nothing && return nothing
    value isa NodeSchema || throw(ArgumentError(
        "expected NodeSchema or nothing, got $(typeof(value))",
    ))
    return value
end

"""
    SchemaDefinition(schema; namespace, compatibility=:exact_read, fields=(),
                     node_schema=nothing, documentation="", package_version="",
                     replaces=nothing, replaced_by=nothing, migration=nothing)

Exact embedded schema revision. Identity is [`SchemaRef`](@ref)
(namespace, schema id, version). `package_version` is provenance only and
must not be treated as schema identity. JLD2 type names are not a field
here on purpose.
"""
struct SchemaDefinition
    schema::SchemaRef
    namespace::ArchiveNamespace
    compatibility::Symbol
    fields::Vector{SchemaField}
    node_schema::Union{Nothing,NodeSchema}
    documentation::String
    package_version::String
    replaces::Union{Nothing,SchemaRef}
    replaced_by::Union{Nothing,SchemaRef}
    migration::Union{Nothing,SchemaMigrationRef}
end

function SchemaDefinition(
    schema::SchemaRef;
    namespace::ArchiveNamespace,
    compatibility::Symbol = :exact_read,
    fields = SchemaField[],
    node_schema = nothing,
    documentation::AbstractString = "",
    package_version::AbstractString = "",
    replaces = nothing,
    replaced_by = nothing,
    migration = nothing,
)
    compatibility in SCHEMA_COMPATIBILITY || throw(ArgumentError(
        "unknown schema compatibility :$compatibility (expected one of $SCHEMA_COMPATIBILITY)",
    ))
    return SchemaDefinition(
        schema,
        namespace,
        compatibility,
        _typed_vector(SchemaField, fields, "schema fields"),
        _optional_node_schema(node_schema),
        String(documentation),
        String(strip(package_version)),
        _optional_schema_ref(replaces),
        _optional_schema_ref(replaced_by),
        _optional_migration(migration),
    )
end

"""
    SchemaRegistry(entries=())

Embedded schema definitions needed by one archive. This is not
[`ArchiveCatalog`](@ref) (identity-only lookup) and not a migration
runner. Physical encoding is #40.
"""
struct SchemaRegistry
    entries::Vector{SchemaDefinition}

    function SchemaRegistry(entries = SchemaDefinition[])
        return new(_typed_vector(SchemaDefinition, entries, "schema definitions"))
    end
end

"""
    SchemaListing

Inspection view of one embedded schema: identity, compatibility, portable
field structure, optional [`NodeSchema`](@ref), and replacement/migration
pointers. Payloads are never loaded.
"""
struct SchemaListing
    schema::SchemaRef
    namespace::ArchiveNamespace
    compatibility::Symbol
    fields::Tuple{Vararg{SchemaField}}
    field_names::Tuple{Vararg{Symbol}}
    node_schema::Union{Nothing,NodeSchema}
    has_node_schema::Bool
    documentation::String
    package_version::String
    replaces::Union{Nothing,SchemaRef}
    replaced_by::Union{Nothing,SchemaRef}
    migration::Union{Nothing,SchemaMigrationRef}
end

function ordered_schemas(registry::SchemaRegistry)
    return sort(registry.entries; by = _schema_sort_key)
end

_schema_sort_key(entry::SchemaDefinition) = (
    String(entry.schema.namespace_id),
    entry.schema.schema_id,
    entry.schema.version,
)

"""
    resolve_schema(schema, registry) -> Union{SchemaDefinition,Nothing}

Exact schema-id/version lookup. Package version is never consulted.
"""
function resolve_schema(schema::SchemaRef, registry::SchemaRegistry)
    for entry in registry.entries
        entry.schema == schema && return entry
    end
    return nothing
end

"""
    schema_status(schema, registry) -> Symbol

`:exact_read`, `:backwards_compatible`, `:migration_required`,
`:unsupported`, or `:missing_schema`.
"""
function schema_status(schema::SchemaRef, registry::SchemaRegistry)
    entry = resolve_schema(schema, registry)
    entry === nothing && return :missing_schema
    return entry.compatibility
end

"""
    known_schemas(registry) -> ArchiveCatalog

Identity/compatibility projection of the embedded registry. JLD2 type
metadata is not copied because it is not schema identity.
"""
function known_schemas(registry::SchemaRegistry)
    return ArchiveCatalog(;
        schemas = [KnownSchema(entry.schema, entry.compatibility) for entry in ordered_schemas(registry)],
    )
end

function find_schema_fields(entry::SchemaDefinition)
    return sort(entry.fields; by = field -> String(field.name))
end

"""
    list_schemas(registry) -> Vector{SchemaListing}
    list_schemas(graph, registry)

Generic structural inspection of embedded schemas. Listings include
portable [`SchemaField`](@ref) facts and the optional [`NodeSchema`](@ref)
so a reader without the owning package can inspect types, units,
rank/shape, references, and SemanticNode attributes. Domain payload
packages are not required.
"""
function list_schemas(registry::SchemaRegistry)
    listings = SchemaListing[]
    for entry in ordered_schemas(registry)
        push!(listings, _schema_listing(entry))
    end
    return listings
end

function list_schemas(graph::ArchiveGraph, registry::SchemaRegistry)
    needed = Set{SchemaRef}()
    for object in graph.objects
        push!(needed, object.schema)
    end
    listings = SchemaListing[]
    for entry in ordered_schemas(registry)
        entry.schema in needed || continue
        push!(listings, _schema_listing(entry))
    end
    return listings
end

function list_schemas(
    manifest::RevisionManifest,
    registry::SchemaRegistry,
)
    objects = ArchiveObject[]
    for entry in manifest.entries
        entry.object isa ArchiveObject && push!(objects, entry.object)
    end
    return list_schemas(ArchiveGraph(objects), registry)
end

function _schema_listing(entry::SchemaDefinition)
    fields = Tuple(find_schema_fields(entry))
    names = ntuple(i -> fields[i].name, length(fields))
    node = entry.node_schema
    return SchemaListing(
        entry.schema,
        entry.namespace,
        entry.compatibility,
        fields,
        names,
        node,
        node !== nothing,
        entry.documentation,
        entry.package_version,
        entry.replaces,
        entry.replaced_by,
        entry.migration,
    )
end

function _validate_schema_field!(diagnostics, field::SchemaField, schema::SchemaRef)
    if !isempty(field.shape) && length(field.shape) != field.rank
        push!(diagnostics, error_diagnostic(
            :corrupt_schema,
            "field :$(field.name) shape length does not match rank $(field.rank)";
            schema_kind = schema_kind(schema),
            version = schema.version,
            field = field.name,
        ))
    end
    return diagnostics
end

function _validate_schema_definition!(diagnostics, entry::SchemaDefinition)
    ns = entry.namespace
    if ns.id !== entry.schema.namespace_id
        push!(diagnostics, error_diagnostic(
            :schema_namespace_mismatch,
            "schema namespace :$(entry.schema.namespace_id) does not match owning namespace :$(ns.id)";
            schema_kind = schema_kind(entry.schema),
            namespace = ns.id,
            schema_namespace = entry.schema.namespace_id,
        ))
    end
    if is_reserved_archive_area(ns.id)
        push!(diagnostics, error_diagnostic(
            :reserved_archive_area_claimed,
            "namespace :$(ns.id) is a reserved archive area, not a package namespace";
            namespace = ns.id,
            schema_kind = schema_kind(entry.schema),
        ))
    end
    if is_reserved_shared_namespace(ns.id)
        uuid = ns.package_uuid
        if !isempty(uuid) && uuid != EPISTEME_PACKAGE_UUID
            push!(diagnostics, error_diagnostic(
                :reserved_namespace_claimed,
                "namespace :$(ns.id) is reserved for Episteme (UUID $EPISTEME_PACKAGE_UUID)";
                namespace = ns.id,
                package_uuid = uuid,
            ))
        end
    elseif startswith(String(schema_kind(entry.schema)), _kind_prefix(EPISTEME_NAMESPACE))
        push!(diagnostics, error_diagnostic(
            :reserved_kind_claimed,
            "kind $(schema_kind(entry.schema)) is reserved for namespace :$EPISTEME_NAMESPACE";
            schema_kind = schema_kind(entry.schema),
            namespace = ns.id,
        ))
    end

    seen = Symbol[]
    for field in entry.fields
        if field.name in seen
            push!(diagnostics, error_diagnostic(
                :corrupt_schema,
                "schema $(schema_kind(entry.schema)) has duplicate field :$(field.name)";
                schema_kind = schema_kind(entry.schema),
                version = entry.schema.version,
                field = field.name,
            ))
        else
            push!(seen, field.name)
        end
        _validate_schema_field!(diagnostics, field, entry.schema)
    end

    if isempty(entry.fields) && entry.node_schema === nothing
        push!(diagnostics, error_diagnostic(
            :corrupt_schema,
            "schema $(schema_kind(entry.schema)) version $(entry.schema.version) has no fields or node schema";
            schema_kind = schema_kind(entry.schema),
            version = entry.schema.version,
        ))
    end

    node = entry.node_schema
    if node !== nothing && node.kind != schema_kind(entry.schema)
        push!(diagnostics, error_diagnostic(
            :corrupt_schema,
            "node schema kind $(node.kind) does not match $(schema_kind(entry.schema))";
            schema_kind = schema_kind(entry.schema),
            version = entry.schema.version,
            node_kind = node.kind,
        ))
    end

    if entry.replaces == entry.schema || entry.replaced_by == entry.schema
        push!(diagnostics, error_diagnostic(
            :corrupt_schema,
            "schema $(schema_kind(entry.schema)) version $(entry.schema.version) replaces or is replaced by itself";
            schema_kind = schema_kind(entry.schema),
            version = entry.schema.version,
        ))
    end
    mig = entry.migration
    if mig !== nothing && entry.replaced_by !== nothing && mig.target != entry.replaced_by
        push!(diagnostics, error_diagnostic(
            :corrupt_schema,
            "schema $(schema_kind(entry.schema)) migration target does not match replaced_by";
            schema_kind = schema_kind(entry.schema),
            version = entry.schema.version,
            migration_target = schema_kind(mig.target),
            replaced_by = schema_kind(entry.replaced_by),
        ))
    end
    if entry.compatibility === :migration_required
        mig = entry.migration
        if mig === nothing
            push!(diagnostics, error_diagnostic(
                :missing_migration_ref,
                "schema $(schema_kind(entry.schema)) version $(entry.schema.version) requires a migration reference";
                schema_kind = schema_kind(entry.schema),
                version = entry.schema.version,
            ))
        elseif mig.source != entry.schema
            push!(diagnostics, error_diagnostic(
                :corrupt_schema,
                "migration source $(schema_kind(mig.source)) $(mig.source.version) does not match this schema";
                schema_kind = schema_kind(entry.schema),
                version = entry.schema.version,
            ))
        end
    end
    return diagnostics
end

function _validate_schema_registry!(
    diagnostics,
    registry::SchemaRegistry;
    namespaces::Union{Nothing,NamespaceRegistry} = nothing,
)
    seen = SchemaRef[]
    for entry in ordered_schemas(registry)
        _validate_schema_definition!(diagnostics, entry)
        if entry.schema in seen
            push!(diagnostics, error_diagnostic(
                :duplicate_schema,
                "schema $(schema_kind(entry.schema)) version $(entry.schema.version) is embedded more than once";
                schema_kind = schema_kind(entry.schema),
                version = entry.schema.version,
            ))
        else
            push!(seen, entry.schema)
        end
    end
    _validate_schema_namespace_identities!(diagnostics, registry, namespaces)
    _validate_embedded_replacement_links!(diagnostics, registry)
    return diagnostics
end

function _validate_embedded_replacement_links!(diagnostics, registry::SchemaRegistry)
    by_ref = Dict{SchemaRef,SchemaDefinition}()
    for entry in registry.entries
        by_ref[entry.schema] = entry
    end
    for entry in ordered_schemas(registry)
        successor = entry.replaced_by
        if successor !== nothing && haskey(by_ref, successor)
            other = by_ref[successor]
            if other.replaces !== nothing && other.replaces != entry.schema
                push!(diagnostics, error_diagnostic(
                    :corrupt_schema,
                    "schema $(schema_kind(successor)) replaces $(schema_kind(other.replaces)), not $(schema_kind(entry.schema))";
                    schema_kind = schema_kind(entry.schema),
                    version = entry.schema.version,
                    replaced_by = schema_kind(successor),
                ))
            end
        end
        predecessor = entry.replaces
        if predecessor !== nothing && haskey(by_ref, predecessor)
            other = by_ref[predecessor]
            if other.replaced_by !== nothing && other.replaced_by != entry.schema
                push!(diagnostics, error_diagnostic(
                    :corrupt_schema,
                    "schema $(schema_kind(predecessor)) is replaced by $(schema_kind(other.replaced_by)), not $(schema_kind(entry.schema))";
                    schema_kind = schema_kind(entry.schema),
                    version = entry.schema.version,
                    replaces = schema_kind(predecessor),
                ))
            end
        end
    end
    return diagnostics
end

function _validate_schema_namespace_identities!(
    diagnostics,
    schemas::SchemaRegistry,
    namespaces::Union{Nothing,NamespaceRegistry} = nothing,
)
    by_id = Dict{Symbol,Vector{String}}()
    by_uuid = Dict{String,Vector{Symbol}}()
    for entry in schemas.entries
        ns = entry.namespace
        uuids = get!(Vector{String}, by_id, ns.id)
        isempty(ns.package_uuid) || ns.package_uuid in uuids || push!(uuids, ns.package_uuid)
        isempty(ns.package_uuid) && continue
        ids = get!(Vector{Symbol}, by_uuid, ns.package_uuid)
        ns.id in ids || push!(ids, ns.id)
    end
    for (id, uuids) in by_id
        length(uuids) <= 1 && continue
        push!(diagnostics, error_diagnostic(
            :namespace_identity_conflict,
            "namespace :$id is claimed by multiple package UUIDs $(Tuple(uuids))";
            namespace = id,
            package_uuids = Tuple(uuids),
        ))
    end
    for (uuid, ids) in by_uuid
        length(ids) <= 1 && continue
        _ids_share_canonical(namespaces, ids, uuid) && continue
        push!(diagnostics, error_diagnostic(
            :namespace_id_split,
            "package UUID $uuid is used as namespaces $(Tuple(ids)) without an alias";
            package_uuid = uuid,
            namespaces = Tuple(sort(ids; by = String)),
        ))
    end
    namespaces === nothing && return diagnostics
    for entry in schemas.entries
        _validate_schema_against_namespaces!(diagnostics, entry, namespaces)
    end
    return diagnostics
end

function _validate_schema_against_namespaces!(
    diagnostics,
    entry::SchemaDefinition,
    namespaces::NamespaceRegistry,
)
    ns = entry.namespace
    claimed = resolve_namespace(namespaces, ns.id)
    claimed === nothing && return diagnostics
    claimed_uuid = claimed.namespace.package_uuid
    if !isempty(claimed_uuid) && isempty(ns.package_uuid)
        push!(diagnostics, error_diagnostic(
            :namespace_identity_missing,
            "schema namespace :$(ns.id) omits package UUID $claimed_uuid required by the registry";
            schema_kind = schema_kind(entry.schema),
            version = entry.schema.version,
            namespace = ns.id,
            registered_uuid = claimed_uuid,
        ))
    elseif !isempty(claimed_uuid) && claimed_uuid != ns.package_uuid
        push!(diagnostics, error_diagnostic(
            :namespace_identity_conflict,
            "schema namespace :$(ns.id) UUID $(ns.package_uuid) does not match registered UUID $claimed_uuid";
            schema_kind = schema_kind(entry.schema),
            version = entry.schema.version,
            namespace = ns.id,
            package_uuid = ns.package_uuid,
            registered_uuid = claimed_uuid,
        ))
    end
    return diagnostics
end

function _validate_graph_schemas!(diagnostics, graph::ArchiveGraph, registry::SchemaRegistry)
    for object in ordered_objects(graph)
        status = schema_status(object.schema, registry)
        if status === :missing_schema
            push!(diagnostics, error_diagnostic(
                :missing_schema,
                "schema $(schema_kind(object.schema)) version $(object.schema.version) is not in the embedded registry";
                object_id = object.object_id.value,
                schema_kind = schema_kind(object.schema),
                version = object.schema.version,
            ))
        elseif status === :unsupported
            push!(diagnostics, error_diagnostic(
                :unsupported_schema,
                "schema $(schema_kind(object.schema)) version $(object.schema.version) is unsupported";
                object_id = object.object_id.value,
                schema_kind = schema_kind(object.schema),
                version = object.schema.version,
            ))
        elseif status === :migration_required
            push!(diagnostics, error_diagnostic(
                :migration_required,
                "schema $(schema_kind(object.schema)) version $(object.schema.version) requires an explicit migration";
                object_id = object.object_id.value,
                schema_kind = schema_kind(object.schema),
                version = object.schema.version,
            ))
        end
    end
    return diagnostics
end

function validate(entry::SchemaDefinition)
    diagnostics = DiagnosticMessage[]
    _validate_schema_definition!(diagnostics, entry)
    return ValidationReport(
        schema_kind(entry.schema),
        isempty(diagnostics),
        diagnostics,
        (;
            schema_id = entry.schema.schema_id,
            version = entry.schema.version,
            compatibility = entry.compatibility,
        ),
    )
end

function validate(registry::SchemaRegistry)
    diagnostics = DiagnosticMessage[]
    _validate_schema_registry!(diagnostics, registry)
    return ValidationReport(
        :schema_registry,
        isempty(diagnostics),
        diagnostics,
        (; schemas = length(registry.entries)),
    )
end

function validate(schemas::SchemaRegistry, namespaces::NamespaceRegistry)
    diagnostics = DiagnosticMessage[]
    _validate_schema_registry!(diagnostics, schemas; namespaces = namespaces)
    _validate_namespace_registry!(diagnostics, namespaces)
    return ValidationReport(
        :schema_registry,
        isempty(diagnostics),
        diagnostics,
        (;
            schemas = length(schemas.entries),
            namespaces = length(namespaces.claims),
        ),
    )
end

function validate(graph::ArchiveGraph, registry::SchemaRegistry)
    diagnostics = DiagnosticMessage[]
    _validate_archive_graph!(diagnostics, graph)
    _validate_schema_registry!(diagnostics, registry)
    _validate_graph_schemas!(diagnostics, graph, registry)
    return ValidationReport(
        :archive_graph,
        isempty(diagnostics),
        diagnostics,
        (; schemas = length(list_schemas(graph, registry))),
    )
end

function validate(
    graph::ArchiveGraph,
    schemas::SchemaRegistry,
    namespaces::NamespaceRegistry,
)
    diagnostics = DiagnosticMessage[]
    _validate_archive_graph!(diagnostics, graph; namespace_registry = namespaces)
    _validate_namespace_registry!(diagnostics, namespaces)
    _validate_schema_registry!(diagnostics, schemas; namespaces = namespaces)
    _validate_graph_schemas!(diagnostics, graph, schemas)
    return ValidationReport(
        :archive_graph,
        isempty(diagnostics),
        diagnostics,
        (;
            schemas = length(list_schemas(graph, schemas)),
            namespaces = length(namespaces.claims),
        ),
    )
end

"""
    validate(node, definition) -> ValidationReport
    validate(payload::NamedTuple, definition) -> ValidationReport

Check a portable payload against an embedded schema. This is structural
validation, not domain science. A live `SemanticNode` may still hold
values that have no portable schema.
"""
function validate(node::SemanticNode, entry::SchemaDefinition)
    diagnostics = DiagnosticMessage[]
    if entry.node_schema !== nothing
        node_report = validate(node, entry.node_schema)
        append!(diagnostics, node_report.diagnostics)
    else
        _validate_payload_fields!(diagnostics, _payload_from_node(node), entry)
    end
    return ValidationReport(
        schema_kind(entry.schema),
        isempty(diagnostics),
        diagnostics,
        (;
            schema_id = entry.schema.schema_id,
            version = entry.schema.version,
            payload = :semantic_node,
        ),
    )
end

function validate(payload::NamedTuple, entry::SchemaDefinition)
    diagnostics = DiagnosticMessage[]
    _validate_payload_fields!(diagnostics, payload, entry)
    return ValidationReport(
        schema_kind(entry.schema),
        isempty(diagnostics),
        diagnostics,
        (;
            schema_id = entry.schema.schema_id,
            version = entry.schema.version,
            payload = :namedtuple,
        ),
    )
end

function _payload_from_node(node::SemanticNode)
    pairs = [name => value for (name, value) in node.attributes]
    return (; pairs...)
end

function _validate_payload_fields!(diagnostics, payload::NamedTuple, entry::SchemaDefinition)
    actual = Set(keys(payload))
    expected = Set(field.name for field in entry.fields)
    for field in entry.fields
        if !(field.name in actual)
            field.required && push!(diagnostics, error_diagnostic(
                :payload_schema_violation,
                "missing required field :$(field.name)";
                field = field.name,
                schema_kind = schema_kind(entry.schema),
                version = entry.schema.version,
                reason = :missing_field,
            ))
            continue
        end
        _validate_payload_value!(diagnostics, payload[field.name], field, entry)
    end
    for name in keys(payload)
        name in expected && continue
        push!(diagnostics, error_diagnostic(
            :payload_schema_violation,
            "unexpected field :$name";
            field = name,
            schema_kind = schema_kind(entry.schema),
            version = entry.schema.version,
            reason = :unexpected_field,
        ))
    end
    return diagnostics
end

function _validate_payload_value!(diagnostics, value, field::SchemaField, entry::SchemaDefinition)
    if field.cardinality === :many
        if !(value isa AbstractVector || value isa Tuple)
            push!(diagnostics, error_diagnostic(
                :payload_schema_violation,
                "field :$(field.name) must be a list";
                field = field.name,
                schema_kind = schema_kind(entry.schema),
                version = entry.schema.version,
                reason = :cardinality,
            ))
            return diagnostics
        end
        for item in value
            _validate_payload_element!(diagnostics, item, field, entry)
        end
        return diagnostics
    end
    return _validate_payload_element!(diagnostics, value, field, entry)
end

function _validate_payload_element!(diagnostics, value, field::SchemaField, entry::SchemaDefinition)
    if field.reference_target !== nothing
        value isa ObjectId || value isa ObjectRef || value isa NodeRef || push!(
            diagnostics,
            error_diagnostic(
                :payload_schema_violation,
                "field :$(field.name) must be a logical reference to $(field.reference_target)";
                field = field.name,
                schema_kind = schema_kind(entry.schema),
                version = entry.schema.version,
                reason = :reference_target,
            ),
        )
        return diagnostics
    end
    if field.rank == 0
        if !_matches_logical_type(value, field.element)
            push!(diagnostics, error_diagnostic(
                :payload_schema_violation,
                "field :$(field.name) must be :$(field.element.kind), got $(typeof(value))";
                field = field.name,
                schema_kind = schema_kind(entry.schema),
                version = entry.schema.version,
                reason = :logical_type,
            ))
            return diagnostics
        end
        _validate_payload_rules!(diagnostics, value, field, entry)
        return diagnostics
    end
    if !(value isa AbstractArray) || ndims(value) != field.rank
        push!(diagnostics, error_diagnostic(
            :payload_schema_violation,
            "field :$(field.name) must be a rank-$(field.rank) array";
            field = field.name,
            schema_kind = schema_kind(entry.schema),
            version = entry.schema.version,
            reason = :array_rank,
        ))
        return diagnostics
    end
    for (dim, extent) in enumerate(field.shape)
        extent === nothing && continue
        size(value, dim) == extent && continue
        push!(diagnostics, error_diagnostic(
            :payload_schema_violation,
            "field :$(field.name) dimension $dim must have extent $extent";
            field = field.name,
            schema_kind = schema_kind(entry.schema),
            version = entry.schema.version,
            reason = :array_shape,
        ))
    end
    for item in value
        if !_matches_logical_type(item, field.element)
            push!(diagnostics, error_diagnostic(
                :payload_schema_violation,
                "field :$(field.name) elements must be :$(field.element.kind)";
                field = field.name,
                schema_kind = schema_kind(entry.schema),
                version = entry.schema.version,
                reason = :logical_type,
            ))
            return diagnostics
        end
    end
    return diagnostics
end

function _matches_logical_type(value, logical::LogicalType)
    kind = logical.kind
    kind === :bool && return value isa Bool
    kind === :integer && return value isa Integer && !(value isa Bool)
    kind === :real && return value isa Real && !(value isa Bool)
    kind === :complex && return value isa Complex
    kind === :string && return value isa AbstractString
    kind === :symbol && return value isa Symbol
    kind === :enum && return value isa Symbol && value in logical.enum_values
    return false
end

function _validate_payload_rules!(diagnostics, value, field::SchemaField, entry::SchemaDefinition)
    for rule in field.rules
        passed = try
            _check_rule(rule, value)
        catch err
            if err isa ArgumentError
                push!(diagnostics, error_diagnostic(
                    :unknown_validation_rule,
                    sprint(showerror, err);
                    field = field.name,
                    rule = rule.kind,
                ))
                false
            else
                rethrow()
            end
        end
        passed && continue
        push!(diagnostics, error_diagnostic(
            :payload_schema_violation,
            isempty(rule.message) ? "field :$(field.name) failed validation rule :$(rule.kind)" :
                rule.message;
            field = field.name,
            schema_kind = schema_kind(entry.schema),
            version = entry.schema.version,
            reason = :validation_rule,
            rule = rule.kind,
        ))
    end
    return diagnostics
end

function report(entry::SchemaDefinition)
    return ObjectReport(
        schema_kind(entry.schema),
        "Embedded schema $(schema_kind(entry.schema)) $(entry.schema.version) ($(entry.compatibility)).",
        to_namedtuple(_schema_listing(entry)),
        DiagnosticMessage[],
        ArtifactRef[],
    )
end

function report(registry::SchemaRegistry)
    n = length(registry.entries)
    noun = n == 1 ? "definition" : "definitions"
    return ObjectReport(
        :schema_registry,
        "Schema registry with $n embedded schema $noun.",
        (;
            schemas = n,
            kinds = Tuple(schema_kind(entry.schema) for entry in ordered_schemas(registry)),
        ),
        DiagnosticMessage[],
        ArtifactRef[],
    )
end

function report(listing::SchemaListing)
    return ObjectReport(
        schema_kind(listing.schema),
        "Schema listing $(schema_kind(listing.schema)) $(listing.schema.version).",
        to_namedtuple(listing),
        DiagnosticMessage[],
        ArtifactRef[],
    )
end

function readiness(registry::SchemaRegistry, target::PipelineTarget)
    target.name === :inspect || return ReadinessReport(
        :schema_registry,
        target,
        false,
        [error_diagnostic(
            :unsupported_target,
            "schema registry readiness target :$(target.name) is not :inspect";
            target = target.name,
        )],
        (; schemas = length(registry.entries)),
    )
    result = validate(registry)
    return ReadinessReport(
        :schema_registry,
        target,
        isvalid(result),
        result.diagnostics,
        (; schemas = length(registry.entries)),
    )
end

to_namedtuple(mig::SchemaMigrationRef) = (
    source = to_namedtuple(mig.source),
    target = to_namedtuple(mig.target),
    implementation_id = mig.implementation_id,
)

to_namedtuple(field::SchemaField) = (
    name = field.name,
    element = to_namedtuple(field.element),
    rank = field.rank,
    shape = field.shape,
    required = field.required,
    cardinality = field.cardinality,
    support = field.support,
    location = field.location,
    reference_target = field.reference_target,
    rules = Tuple(to_namedtuple.(field.rules)),
    documentation = field.documentation,
)

function to_namedtuple(entry::SchemaDefinition)
    return (
        schema = to_namedtuple(entry.schema),
        namespace = to_namedtuple(entry.namespace),
        compatibility = entry.compatibility,
        fields = Tuple(to_namedtuple.(find_schema_fields(entry))),
        node_schema = entry.node_schema === nothing ? nothing : to_namedtuple(entry.node_schema),
        documentation = entry.documentation,
        package_version = entry.package_version,
        replaces = entry.replaces === nothing ? nothing : to_namedtuple(entry.replaces),
        replaced_by = entry.replaced_by === nothing ? nothing : to_namedtuple(entry.replaced_by),
        migration = entry.migration === nothing ? nothing : to_namedtuple(entry.migration),
    )
end

to_namedtuple(registry::SchemaRegistry) = (
    entries = Tuple(to_namedtuple.(ordered_schemas(registry))),
)

to_namedtuple(listing::SchemaListing) = (
    schema = to_namedtuple(listing.schema),
    namespace = to_namedtuple(listing.namespace),
    compatibility = listing.compatibility,
    fields = Tuple(to_namedtuple.(listing.fields)),
    field_names = listing.field_names,
    node_schema = listing.node_schema === nothing ? nothing : to_namedtuple(listing.node_schema),
    has_node_schema = listing.has_node_schema,
    documentation = listing.documentation,
    package_version = listing.package_version,
    replaces = listing.replaces === nothing ? nothing : to_namedtuple(listing.replaces),
    replaced_by = listing.replaced_by === nothing ? nothing : to_namedtuple(listing.replaced_by),
    migration = listing.migration === nothing ? nothing : to_namedtuple(listing.migration),
)

function from_namedtuple(::Type{SchemaRef}, nt)
    return SchemaRef(Symbol(nt.namespace_id), String(nt.schema_id), String(nt.version))
end

function from_namedtuple(::Type{LogicalType}, nt)
    return LogicalType(
        Symbol(nt.kind);
        units = nt.units,
        frame = nt.frame,
        enum_values = Tuple(Symbol(v) for v in nt.enum_values),
    )
end

function from_namedtuple(::Type{ValidationRule}, nt)
    parameters = nt.parameters isa NamedTuple ? nt.parameters : (;)
    return ValidationRule(Symbol(nt.kind); message = String(nt.message), parameters...)
end

function from_namedtuple(::Type{AttributeSchema}, nt)
    rules = ValidationRule[from_namedtuple(ValidationRule, rule) for rule in nt.rules]
    return AttributeSchema(
        Symbol(nt.name),
        Symbol(nt.value_kind);
        required = nt.required,
        allow_ref = nt.allow_ref,
        rules = rules,
    )
end

function from_namedtuple(::Type{NodeValidationRule}, nt)
    parameters = nt.parameters isa NamedTuple ? nt.parameters : (;)
    return NodeValidationRule(Symbol(nt.kind); message = String(nt.message), parameters...)
end

function from_namedtuple(::Type{NodeSchema}, nt)
    attributes = AttributeSchema[from_namedtuple(AttributeSchema, field) for field in nt.attributes]
    rules = NodeValidationRule[from_namedtuple(NodeValidationRule, rule) for rule in nt.rules]
    return NodeSchema(Symbol(nt.kind), attributes...; allow_extra = nt.allow_extra, rules = rules)
end

function from_namedtuple(::Type{SchemaMigrationRef}, nt)
    return SchemaMigrationRef(
        from_namedtuple(SchemaRef, nt.source),
        from_namedtuple(SchemaRef, nt.target);
        implementation_id = String(nt.implementation_id),
    )
end

function from_namedtuple(::Type{SchemaField}, nt)
    target = nt.reference_target === nothing ? nothing : Symbol(nt.reference_target)
    rules = ValidationRule[from_namedtuple(ValidationRule, rule) for rule in nt.rules]
    return SchemaField(
        Symbol(nt.name),
        from_namedtuple(LogicalType, nt.element);
        rank = nt.rank,
        shape = nt.shape,
        required = nt.required,
        cardinality = Symbol(nt.cardinality),
        support = String(nt.support),
        location = String(nt.location),
        reference_target = target,
        rules = rules,
        documentation = String(nt.documentation),
    )
end

function from_namedtuple(::Type{ArchiveNamespace}, nt)
    return ArchiveNamespace(
        Symbol(nt.id);
        package_uuid = String(nt.package_uuid),
        display_name = String(nt.display_name),
    )
end

function from_namedtuple(::Type{SchemaDefinition}, nt)
    node = nt.node_schema === nothing ? nothing : from_namedtuple(NodeSchema, nt.node_schema)
    replaces = nt.replaces === nothing ? nothing : from_namedtuple(SchemaRef, nt.replaces)
    replaced_by = nt.replaced_by === nothing ? nothing : from_namedtuple(SchemaRef, nt.replaced_by)
    migration = nt.migration === nothing ? nothing : from_namedtuple(SchemaMigrationRef, nt.migration)
    fields = SchemaField[from_namedtuple(SchemaField, field) for field in nt.fields]
    return SchemaDefinition(
        from_namedtuple(SchemaRef, nt.schema);
        namespace = from_namedtuple(ArchiveNamespace, nt.namespace),
        compatibility = Symbol(nt.compatibility),
        fields = fields,
        node_schema = node,
        documentation = String(nt.documentation),
        package_version = String(nt.package_version),
        replaces = replaces,
        replaced_by = replaced_by,
        migration = migration,
    )
end

function from_namedtuple(::Type{SchemaRegistry}, nt)
    entries = SchemaDefinition[from_namedtuple(SchemaDefinition, entry) for entry in nt.entries]
    return SchemaRegistry(entries)
end
