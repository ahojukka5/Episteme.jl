# ---------------------------------------------------------------------------
# AH5 profile, JLD2 writer, and generic file inspector (#40)
#
# `.ah5` is Episteme's versioned scientific-archive profile on an ordinary
# HDF5-format file created by JLD2. Identity is in-file metadata, not the
# filename extension. JLD2 `/_types` is Julia representation, not profile
# identity. HDF5.jl is not required here; bulk `/data` remains a later
# EpistemeHDF5Ext path.
# ---------------------------------------------------------------------------

const AH5_MAGIC = "AH5"
const AH5_PROFILE_VERSION = "1.0.0"
const HDF5_SIGNATURE = UInt8[0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a]
const JLD2_HEADER_PREFIX = codeunits("HDF5-based Julia Data Format")

const AH5_PROFILE_KEY = "episteme/profile"
const AH5_NAMESPACES_KEY = "episteme/namespaces"
const AH5_SCHEMAS_KEY = "episteme/schemas"
const AH5_HISTORY_KEY = "episteme/history"
const AH5_PROVENANCE_KEY = "episteme/provenance"
const AH5_EXTERNALS_KEY = "episteme/externals"

const AH5_SUPPORTED_FEATURES = (
    :jld2_writer,
    :namespaces,
    :embedded_schemas,
    :history,
    :provenance,
    :externals,
)
const AH5_V1_FEATURES = AH5_SUPPORTED_FEATURES
const AH5_INTERPRETATION_BLOCKERS = (
    :unsupported_profile_version,
    :unsupported_required_feature,
    :required_feature_missing,
    :invalid_archive_root,
)

"""
    ArchiveProfileRoots

Physical JLD2/HDF5 paths for inspectable AH5 records. The profile itself
always lives at [`AH5_PROFILE_KEY`](@ref). Other groups follow these
paths. They are not package namespaces and not scientific schema identity.
"""
struct ArchiveProfileRoots
    namespaces::String
    schemas::String
    history::String
    provenance::String
    externals::String
end

function ArchiveProfileRoots(;
    namespaces::AbstractString = AH5_NAMESPACES_KEY,
    schemas::AbstractString = AH5_SCHEMAS_KEY,
    history::AbstractString = AH5_HISTORY_KEY,
    provenance::AbstractString = AH5_PROVENANCE_KEY,
    externals::AbstractString = AH5_EXTERNALS_KEY,
)
    return ArchiveProfileRoots(
        String(namespaces),
        String(schemas),
        String(history),
        String(provenance),
        String(externals),
    )
end

"""
    ArchiveProfile

Domain-neutral AH5 root record. `profile_version` is independent of the
Episteme package version and of payload-schema versions.
`package_version` is provenance only.
"""
struct ArchiveProfile
    magic::String
    profile_version::String
    archive_id::String
    created_at::String
    creator::String
    features::Tuple{Vararg{Symbol}}
    required_features::Tuple{Vararg{Symbol}}
    roots::ArchiveProfileRoots
    package_version::String
end

function ArchiveProfile(;
    magic::AbstractString = AH5_MAGIC,
    profile_version::AbstractString = AH5_PROFILE_VERSION,
    archive_id::AbstractString = string(UUIDs.uuid4()),
    created_at::AbstractString = _ah5_timestamp(),
    creator::AbstractString = "Episteme.jl",
    features = (:jld2_writer,),
    required_features = (),
    roots::ArchiveProfileRoots = ArchiveProfileRoots(),
    package_version::AbstractString = string(pkgversion(@__MODULE__)),
)
    stripped_magic = String(strip(magic))
    stripped_version = String(strip(profile_version))
    stripped_id = String(strip(archive_id))
    isempty(stripped_magic) && throw(ArgumentError("AH5 magic must not be empty"))
    isempty(stripped_version) && throw(ArgumentError("AH5 profile version must not be empty"))
    isempty(stripped_id) && throw(ArgumentError("AH5 archive id must not be empty"))
    return ArchiveProfile(
        stripped_magic,
        stripped_version,
        stripped_id,
        String(created_at),
        String(creator),
        _symbol_tuple(features, "AH5 features"),
        _symbol_tuple(required_features, "AH5 required features"),
        roots,
        String(strip(package_version)),
    )
end

"""
    ArchiveHistorySummary

Counts and head names for generic inspection. Payload bytes are never
included.
"""
struct ArchiveHistorySummary
    objects::Int
    heads::Int
    revisions::Int
    runs::Int
    events::Int
    writes::Int
    log_streams::Int
    head_names::Tuple{Vararg{Symbol}}
end

function ArchiveHistorySummary(
    graph::ArchiveGraph,
)
    heads = ordered_heads(graph)
    return ArchiveHistorySummary(
        length(graph.objects),
        length(graph.heads),
        length(graph.revisions),
        length(graph.runs),
        length(graph.events),
        length(graph.writes),
        length(graph.log_streams),
        Tuple(head.name for head in heads),
    )
end

ArchiveHistorySummary() = ArchiveHistorySummary(0, 0, 0, 0, 0, 0, 0, ())

"""
    ArchiveProvenanceSummary

Software-environment and execution-context identities observed on
envelope records. Full manifests are issues #37 and #43.
"""
struct ArchiveProvenanceSummary
    software_environments::Tuple{Vararg{String}}
    execution_contexts::Tuple{Vararg{String}}
end

function ArchiveProvenanceSummary(graph::ArchiveGraph)
    software = String[]
    contexts = String[]
    for object in ordered_objects(graph)
        sw = object.provenance.software_environment
        if sw !== nothing && !(sw.value in software)
            push!(software, sw.value)
        end
        ctx = object.provenance.execution_context
        if ctx !== nothing && !(ctx.value in contexts)
            push!(contexts, ctx.value)
        end
    end
    return ArchiveProvenanceSummary(Tuple(software), Tuple(contexts))
end

ArchiveProvenanceSummary() = ArchiveProvenanceSummary((), ())

"""
    ArchiveInspection

Generic view of one `.ah5` file. Domain payload packages are not loaded.
"""
struct ArchiveInspection
    path::String
    identified::Bool
    profile::Union{Nothing,ArchiveProfile}
    namespaces::Vector{NamespaceListing}
    schemas::Vector{SchemaListing}
    history::ArchiveHistorySummary
    provenance::ArchiveProvenanceSummary
    externals::Vector{ExternalRequirement}
    diagnostics::Vector{DiagnosticMessage}
end

_ah5_timestamp() = Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SSZ")

function _profile_major(version::AbstractString)
    part = split(String(version), '.'; limit = 2)[1]
    n = tryparse(Int, part)
    return n
end

function is_hdf5_container(path::AbstractString)
    isfile(path) || return false
    return open(path, "r") do io
        nbytes = Int(min(filesize(io), 65536))
        nbytes < length(HDF5_SIGNATURE) && return false
        data = read(io, nbytes)
        if length(data) >= length(JLD2_HEADER_PREFIX) &&
                view(data, 1:length(JLD2_HEADER_PREFIX)) == JLD2_HEADER_PREFIX
            return true
        end
        offset = 0
        while offset + length(HDF5_SIGNATURE) <= length(data)
            if view(data, offset + 1:offset + length(HDF5_SIGNATURE)) == HDF5_SIGNATURE
                return true
            end
            offset = offset == 0 ? 512 : 2 * offset
        end
        return false
    end
end

"""
    write_archive(path; graph=nothing, namespaces=nothing, schemas=nothing,
                  externals=(), profile=nothing, kwargs...)

Create a JLD2-backed AH5 file. The path is created by JLD2. Existing
paths are refused. Domain payloads are not written. Logical metadata is
validated before the file is created; inspectable groups follow
`profile.roots`. Records are stored as `plain=true`-safe values.
"""
function write_archive(
    path::AbstractString;
    graph = nothing,
    namespaces = nothing,
    schemas = nothing,
    externals = ExternalRequirement[],
    profile = nothing,
    kwargs...,
)
    ispath(path) && throw(ArgumentError("archive already exists: $path"))
    graph === nothing || graph isa ArchiveGraph || throw(ArgumentError(
        "graph must be ArchiveGraph or nothing, got $(typeof(graph))",
    ))
    namespaces === nothing || namespaces isa NamespaceRegistry || throw(ArgumentError(
        "namespaces must be NamespaceRegistry or nothing, got $(typeof(namespaces))",
    ))
    schemas === nothing || schemas isa SchemaRegistry || throw(ArgumentError(
        "schemas must be SchemaRegistry or nothing, got $(typeof(schemas))",
    ))
    profile_record = profile === nothing ? ArchiveProfile(; kwargs...) : profile
    profile === nothing || isempty(kwargs) || throw(ArgumentError(
        "pass either profile= or ArchiveProfile keywords, not both",
    ))
    profile_record isa ArchiveProfile || throw(ArgumentError(
        "profile must be ArchiveProfile, got $(typeof(profile_record))",
    ))
    profile_record = _published_profile(profile_record)
    _refuse_invalid_profile(profile_record)
    _refuse_invalid_payload(graph, namespaces, schemas)

    objects = graph === nothing ? ArchiveObject[] : graph.objects
    ns_listings = namespaces === nothing && graph === nothing ?
        NamespaceListing[] : list_namespaces(objects, namespaces)
    schema_listings = schemas === nothing ? SchemaListing[] : list_schemas(schemas)
    history = graph === nothing ? ArchiveHistorySummary() : ArchiveHistorySummary(graph)
    provenance = graph === nothing ? ArchiveProvenanceSummary() : ArchiveProvenanceSummary(graph)
    external_values = _typed_vector(ExternalRequirement, externals, "external requirements")
    roots = profile_record.roots

    JLD2.jldopen(path, "w") do file
        file[AH5_PROFILE_KEY] = _profile_storage(profile_record)
        _write_indexed!(file, roots.namespaces, ns_listings, _namespace_listing_storage)
        _write_indexed!(file, roots.schemas, schema_listings, _schema_listing_storage)
        file[roots.history] = _history_storage(history)
        file[roots.provenance] = _provenance_storage(provenance)
        _write_indexed!(file, roots.externals, external_values, _external_storage)
    end
    return path
end

"""
    inspect_archive(path) -> ArchiveInspection

Read AH5 profile metadata without domain packages or payload load.
Forensic JLD2 `plain=true` is the default reader. The tiny profile is
validated first; unsupported versions or required features return an
identified archive without decoding remaining roots. Full Julia-native
object reconstruction is not this API.
"""
function inspect_archive(path::AbstractString)
    diagnostics = DiagnosticMessage[]
    empty = _empty_inspection(path, diagnostics)
    if !ispath(path)
        push!(diagnostics, error_diagnostic(
            :missing_archive,
            "archive path does not exist: $path";
            path = String(path),
        ))
        return empty
    end
    if !is_hdf5_container(path)
        push!(diagnostics, error_diagnostic(
            :not_ah5_archive,
            "file is not an HDF5-format AH5 archive";
            path = String(path),
        ))
        return empty
    end

    try
        return JLD2.jldopen(path, "r"; plain = true) do file
            return _inspect_open_archive(path, file, diagnostics)
        end
    catch err
        push!(diagnostics, error_diagnostic(
            :not_ah5_archive,
            "file is HDF5-format but has no readable AH5 profile";
            path = String(path),
            reason = sprint(showerror, err),
        ))
        return empty
    end
end

function is_ah5_archive(path::AbstractString)
    inspection = inspect_archive(path)
    return inspection.identified
end

function _inspect_open_archive(path, file, diagnostics)
    raw_profile = _jld2_get(file, AH5_PROFILE_KEY)
    if raw_profile === nothing
        push!(diagnostics, error_diagnostic(
            :missing_profile,
            "mandatory AH5 profile record $(AH5_PROFILE_KEY) is missing";
            path = String(path),
        ))
        return _empty_inspection(path, diagnostics)
    end

    profile = try
        from_namedtuple(ArchiveProfile, raw_profile)
    catch err
        push!(diagnostics, error_diagnostic(
            :corrupt_profile,
            "AH5 profile metadata is corrupt";
            path = String(path),
            reason = sprint(showerror, err),
        ))
        return _empty_inspection(path, diagnostics)
    end

    identified = profile.magic == AH5_MAGIC
    if !identified
        push!(diagnostics, error_diagnostic(
            :not_ah5_archive,
            "in-file magic $(repr(profile.magic)) is not $AH5_MAGIC";
            path = String(path),
            magic = profile.magic,
        ))
    end
    _validate_archive_profile!(diagnostics, profile)
    if !identified || _blocks_interpretation(diagnostics)
        return ArchiveInspection(
            String(path),
            identified,
            identified ? profile : nothing,
            NamespaceListing[],
            SchemaListing[],
            ArchiveHistorySummary(),
            ArchiveProvenanceSummary(),
            ExternalRequirement[],
            diagnostics,
        )
    end

    namespaces = NamespaceListing[]
    schemas = SchemaListing[]
    history = ArchiveHistorySummary()
    provenance = ArchiveProvenanceSummary()
    externals = ExternalRequirement[]
    try
        namespaces = _read_indexed(
            NamespaceListing, file, profile.roots.namespaces, _restore_namespace_listing,
        )
        schemas = _read_indexed(
            SchemaListing, file, profile.roots.schemas, _restore_schema_listing,
        )
        raw_history = _jld2_get(file, profile.roots.history)
        history = raw_history === nothing ? ArchiveHistorySummary() :
            from_namedtuple(ArchiveHistorySummary, raw_history)
        raw_prov = _jld2_get(file, profile.roots.provenance)
        provenance = raw_prov === nothing ? ArchiveProvenanceSummary() :
            from_namedtuple(ArchiveProvenanceSummary, raw_prov)
        externals = _read_indexed(
            ExternalRequirement, file, profile.roots.externals, _restore_external,
        )
    catch err
        push!(diagnostics, error_diagnostic(
            :corrupt_profile,
            "AH5 inspectable records are corrupt";
            path = String(path),
            reason = sprint(showerror, err),
        ))
    end

    return ArchiveInspection(
        String(path),
        identified,
        profile,
        namespaces,
        schemas,
        history,
        provenance,
        externals,
        diagnostics,
    )
end

function _empty_inspection(path, diagnostics)
    return ArchiveInspection(
        String(path),
        false,
        nothing,
        NamespaceListing[],
        SchemaListing[],
        ArchiveHistorySummary(),
        ArchiveProvenanceSummary(),
        ExternalRequirement[],
        diagnostics,
    )
end

function _jld2_get(file, key::AbstractString)
    haskey(file, key) || return nothing
    return file[key]
end

function _count_key(root::AbstractString)
    return string(root, "/count")
end

function _entry_key(root::AbstractString, index::Integer)
    return string(root, "/", index)
end

function _write_indexed!(file, root, records, encoder)
    file[_count_key(root)] = length(records)
    for (index, record) in enumerate(records)
        file[_entry_key(root, index)] = encoder(record)
    end
    return file
end

function _read_indexed(::Type{T}, file, root, decoder) where {T}
    raw_count = _jld2_get(file, _count_key(root))
    raw_count === nothing && return T[]
    typed = T[]
    for index in 1:Int(raw_count)
        raw = _jld2_get(file, _entry_key(root, index))
        raw === nothing && throw(ArgumentError("missing AH5 record $root/$index"))
        push!(typed, decoder(raw))
    end
    return typed
end

function _string_storage(values)
    return String[String(value) for value in values]
end

function _profile_storage(profile::ArchiveProfile)
    nt = to_namedtuple(profile)
    return merge(nt, (
        features = _string_storage(profile.features),
        required_features = _string_storage(profile.required_features),
        roots = to_namedtuple(profile.roots),
    ))
end

function _history_storage(history::ArchiveHistorySummary)
    return (
        objects = history.objects,
        heads = history.heads,
        revisions = history.revisions,
        runs = history.runs,
        events = history.events,
        writes = history.writes,
        log_streams = history.log_streams,
        head_names = _string_storage(history.head_names),
    )
end

function _provenance_storage(prov::ArchiveProvenanceSummary)
    return (
        software_environments = _string_storage(prov.software_environments),
        execution_contexts = _string_storage(prov.execution_contexts),
    )
end

function _namespace_listing_storage(listing::NamespaceListing)
    return (
        id = String(listing.namespace.id),
        package_uuid = listing.namespace.package_uuid,
        display_name = listing.namespace.display_name,
        role = String(listing.role),
        status = String(listing.status),
        canonical_id = String(listing.canonical_id),
        aliases = _string_storage(listing.aliases),
        kinds = _string_storage(listing.kinds),
        schema_ids = _string_storage(listing.schema_ids),
    )
end

function _restore_namespace_listing(nt)
    return from_namedtuple(NamespaceListing, nt)
end

function _external_storage(req::ExternalRequirement)
    return (
        object_id = req.object_id.value,
        content_id = req.content_id === nothing ? "" : req.content_id.value,
        artifact_kind = String(req.artifact.kind),
        artifact_path = req.artifact.path === nothing ? "" : req.artifact.path,
        artifact_uri = req.artifact.uri === nothing ? "" : req.artifact.uri,
        artifact_description = req.artifact.description,
    )
end

function _restore_external(nt)
    content = String(nt.content_id)
    path = String(nt.artifact_path)
    uri = String(nt.artifact_uri)
    return ExternalRequirement(
        ObjectId(String(nt.object_id));
        content_id = isempty(content) ? nothing : ContentId(content),
        artifact = ArtifactRef(
            Symbol(nt.artifact_kind);
            path = isempty(path) ? nothing : path,
            uri = isempty(uri) ? nothing : uri,
            description = String(nt.artifact_description),
        ),
    )
end

function _schema_listing_storage(listing::SchemaListing)
    fields = listing.fields
    node = listing.node_schema
    attrs = node === nothing ? AttributeSchema[] : node.attributes
    node_rules = node === nothing ? NodeValidationRule[] : node.rules
    replaces = listing.replaces
    replaced_by = listing.replaced_by
    migration = listing.migration
    return (
        namespace_id = String(listing.schema.namespace_id),
        schema_id = listing.schema.schema_id,
        version = listing.schema.version,
        package_uuid = listing.namespace.package_uuid,
        display_name = listing.namespace.display_name,
        compatibility = String(listing.compatibility),
        documentation = listing.documentation,
        package_version = listing.package_version,
        field_names = String[String(field.name) for field in fields],
        field_kinds = String[String(field.element.kind) for field in fields],
        field_units = String[field.element.units for field in fields],
        field_frames = String[field.element.frame for field in fields],
        field_enums = String[_encode_symbols(field.element.enum_values) for field in fields],
        field_ranks = Int[field.rank for field in fields],
        field_shapes = String[_encode_shape(field.shape) for field in fields],
        field_required = Bool[field.required for field in fields],
        field_cardinality = String[String(field.cardinality) for field in fields],
        field_support = String[field.support for field in fields],
        field_location = String[field.location for field in fields],
        field_refs = String[
            field.reference_target === nothing ? "" : String(field.reference_target)
            for field in fields
        ],
        field_docs = String[field.documentation for field in fields],
        field_rules = String[_encode_rules(field.rules) for field in fields],
        has_node_schema = listing.has_node_schema,
        node_kind = node === nothing ? "" : String(node.kind),
        node_allow_extra = node === nothing ? false : node.allow_extra,
        attr_names = String[String(attr.name) for attr in attrs],
        attr_kinds = String[String(attr.value_kind) for attr in attrs],
        attr_required = Bool[attr.required for attr in attrs],
        attr_allow_ref = Bool[attr.allow_ref for attr in attrs],
        attr_rules = String[_encode_rules(attr.rules) for attr in attrs],
        node_rule_kinds = String[String(rule.kind) for rule in node_rules],
        node_rule_params = String[_encode_parameters(rule.parameters) for rule in node_rules],
        node_rule_messages = String[rule.message for rule in node_rules],
        replaces_ns = replaces === nothing ? "" : String(replaces.namespace_id),
        replaces_id = replaces === nothing ? "" : replaces.schema_id,
        replaces_version = replaces === nothing ? "" : replaces.version,
        replaced_by_ns = replaced_by === nothing ? "" : String(replaced_by.namespace_id),
        replaced_by_id = replaced_by === nothing ? "" : replaced_by.schema_id,
        replaced_by_version = replaced_by === nothing ? "" : replaced_by.version,
        migration_source_ns = migration === nothing ? "" : String(migration.source.namespace_id),
        migration_source_id = migration === nothing ? "" : migration.source.schema_id,
        migration_source_version = migration === nothing ? "" : migration.source.version,
        migration_target_ns = migration === nothing ? "" : String(migration.target.namespace_id),
        migration_target_id = migration === nothing ? "" : migration.target.schema_id,
        migration_target_version = migration === nothing ? "" : migration.target.version,
        migration_impl = migration === nothing ? "" : migration.implementation_id,
    )
end

function _restore_schema_listing(nt)
    names = _string_vec(nt.field_names)
    kinds = _string_vec(nt.field_kinds)
    units = _string_vec(nt.field_units)
    frames = _string_vec(nt.field_frames)
    enums = _string_vec(nt.field_enums)
    ranks = _int_vec(nt.field_ranks)
    shapes = _string_vec(nt.field_shapes)
    required = _bool_vec(nt.field_required)
    cardinality = _string_vec(nt.field_cardinality)
    support = _string_vec(nt.field_support)
    location = _string_vec(nt.field_location)
    refs = _string_vec(nt.field_refs)
    docs = _string_vec(nt.field_docs)
    rules = _string_vec(nt.field_rules)
    fields = SchemaField[]
    for i in eachindex(names)
        target = isempty(refs[i]) ? nothing : Symbol(refs[i])
        push!(fields, SchemaField(
            Symbol(names[i]),
            LogicalType(
                Symbol(kinds[i]);
                units = units[i],
                frame = frames[i],
                enum_values = Tuple(_decode_symbols(enums[i])),
            );
            rank = ranks[i],
            shape = _decode_shape(shapes[i]),
            required = required[i],
            cardinality = Symbol(cardinality[i]),
            support = support[i],
            location = location[i],
            reference_target = target,
            rules = _decode_rules(rules[i]),
            documentation = docs[i],
        ))
    end
    node = nothing
    if _as_bool(nt.has_node_schema) && !isempty(String(nt.node_kind))
        attr_names = _string_vec(nt.attr_names)
        attr_kinds = _string_vec(nt.attr_kinds)
        attr_required = _bool_vec(nt.attr_required)
        attr_allow_ref = _bool_vec(nt.attr_allow_ref)
        attr_rules = _string_vec(nt.attr_rules)
        attributes = AttributeSchema[]
        for i in eachindex(attr_names)
            push!(attributes, AttributeSchema(
                Symbol(attr_names[i]),
                Symbol(attr_kinds[i]);
                required = attr_required[i],
                allow_ref = attr_allow_ref[i],
                rules = _decode_rules(attr_rules[i]),
            ))
        end
        node_rules = NodeValidationRule[]
        rule_kinds = _string_vec(nt.node_rule_kinds)
        rule_params = _string_vec(nt.node_rule_params)
        rule_messages = _string_vec(nt.node_rule_messages)
        for i in eachindex(rule_kinds)
            params = _decode_parameters(rule_params[i])
            push!(node_rules, NodeValidationRule(
                Symbol(rule_kinds[i]);
                message = rule_messages[i],
                params...,
            ))
        end
        node = NodeSchema(
            Symbol(nt.node_kind),
            attributes...;
            allow_extra = _as_bool(nt.node_allow_extra),
            rules = node_rules,
        )
    end
    schema = SchemaRef(Symbol(nt.namespace_id), String(nt.schema_id), String(nt.version))
    field_tuple = Tuple(fields)
    return SchemaListing(
        schema,
        ArchiveNamespace(
            Symbol(nt.namespace_id);
            package_uuid = String(nt.package_uuid),
            display_name = String(nt.display_name),
        ),
        Symbol(nt.compatibility),
        field_tuple,
        ntuple(i -> field_tuple[i].name, length(field_tuple)),
        node,
        node !== nothing,
        String(nt.documentation),
        String(nt.package_version),
        _schema_ref_parts(nt.replaces_ns, nt.replaces_id, nt.replaces_version),
        _schema_ref_parts(nt.replaced_by_ns, nt.replaced_by_id, nt.replaced_by_version),
        _migration_parts(nt),
    )
end

function _schema_ref_parts(ns, schema_id, version)
    namespace = String(ns)
    id = String(schema_id)
    ver = String(version)
    (isempty(namespace) || isempty(id) || isempty(ver)) && return nothing
    return SchemaRef(Symbol(namespace), id, ver)
end

function _migration_parts(nt)
    source = _schema_ref_parts(
        nt.migration_source_ns, nt.migration_source_id, nt.migration_source_version,
    )
    target = _schema_ref_parts(
        nt.migration_target_ns, nt.migration_target_id, nt.migration_target_version,
    )
    source === nothing && return nothing
    target === nothing && return nothing
    return SchemaMigrationRef(source, target; implementation_id = String(nt.migration_impl))
end

function _encode_symbols(values)
    return join(String.(values), ",")
end

function _decode_symbols(text::AbstractString)
    isempty(text) && return Symbol[]
    return Symbol[Symbol(part) for part in split(String(text), ',')]
end

function _encode_shape(shape)
    return join((dim === nothing ? "?" : string(dim) for dim in shape), ",")
end

function _decode_shape(text::AbstractString)
    isempty(text) && return ()
    dims = Union{Nothing,Int}[]
    for part in split(String(text), ',')
        if part == "?" || isempty(part)
            push!(dims, nothing)
        else
            push!(dims, parse(Int, part))
        end
    end
    return Tuple(dims)
end

function _encode_parameters(nt::NamedTuple)
    isempty(nt) && return ""
    return join(
        (string(key, "=", _encode_param_value(value)) for (key, value) in pairs(nt)),
        ",",
    )
end

function _decode_parameters(text::AbstractString)
    isempty(text) && return NamedTuple()
    items = Pair{Symbol,Any}[]
    for part in split(String(text), ',')
        isempty(part) && continue
        key, value = split(part, '='; limit = 2)
        push!(items, Symbol(key) => _decode_param_value(value))
    end
    return NamedTuple(items)
end

function _encode_param_value(value)
    value isa Symbol && return string(":", value)
    value isa Bool && return value ? "true" : "false"
    value isa Integer && return string(Int(value))
    value isa AbstractFloat && return string(Float64(value))
    if value isa Tuple || value isa AbstractVector
        return join(_encode_param_value.(value), "+")
    end
    return String(value)
end

function _decode_param_value(token::AbstractString)
    token == "true" && return true
    token == "false" && return false
    startswith(token, ":") && return Symbol(SubString(token, 2))
    if occursin('+', token)
        return Tuple(_decode_param_value(part) for part in split(token, '+'))
    end
    integer = tryparse(Int, token)
    integer !== nothing && return integer
    float = tryparse(Float64, token)
    float !== nothing && return float
    return String(token)
end

function _encode_rules(rules)
    parts = String[]
    for rule in rules
        push!(parts, string(
            rule.kind, '\t',
            _encode_parameters(rule.parameters), '\t',
            rule.message,
        ))
    end
    return join(parts, '\n')
end

function _decode_rules(text::AbstractString)
    isempty(text) && return ValidationRule[]
    rules = ValidationRule[]
    for line in split(String(text), '\n')
        isempty(line) && continue
        kind, params, message = split(line, '\t'; limit = 3)
        decoded = _decode_parameters(params)
        push!(rules, ValidationRule(Symbol(kind); message = String(message), decoded...))
    end
    return rules
end

function _string_vec(value)
    value === nothing && return String[]
    return String[String(item) for item in value]
end

function _int_vec(value)
    value === nothing && return Int[]
    return Int[Int(item) for item in value]
end

function _bool_vec(value)
    value === nothing && return Bool[]
    return Bool[_as_bool(item) for item in value]
end

function _as_bool(value)
    value isa Bool && return value
    value isa Integer && return value != 0
    value isa AbstractString && return value == "true"
    return Bool(value)
end

function _feature_tuple(value)
    value === nothing && return ()
    value isa AbstractString && return (Symbol(value),)
    if value isa NamedTuple
        return Tuple(Symbol(item) for item in values(value))
    end
    return Tuple(Symbol(item) for item in value)
end

function _published_features(profile::ArchiveProfile)
    seen = Symbol[]
    for feature in AH5_V1_FEATURES
        feature in seen || push!(seen, feature)
    end
    for feature in profile.features
        feature in seen || push!(seen, feature)
    end
    return Tuple(seen)
end

function _published_profile(profile::ArchiveProfile)
    return ArchiveProfile(
        profile.magic,
        profile.profile_version,
        profile.archive_id,
        profile.created_at,
        profile.creator,
        _published_features(profile),
        profile.required_features,
        profile.roots,
        profile.package_version,
    )
end

function _refuse_invalid_profile(profile::ArchiveProfile)
    diagnostics = DiagnosticMessage[]
    _validate_profile_consistency!(diagnostics, profile)
    isempty(diagnostics) && return profile
    codes = Tuple(item.code for item in diagnostics)
    throw(ArgumentError("refusing to write invalid AH5 profile: $codes"))
end

function _refuse_invalid_payload(graph, namespaces, schemas)
    if graph !== nothing && !isempty(graph.objects) && schemas === nothing
        throw(ArgumentError(
            "refusing to write AH5 archive: graph objects require an embedded SchemaRegistry",
        ))
    end
    report = if graph !== nothing && schemas !== nothing && namespaces !== nothing
        validate(graph, schemas, namespaces)
    elseif graph !== nothing && schemas !== nothing
        validate(graph, schemas)
    elseif graph !== nothing && namespaces !== nothing
        validate(graph, namespaces)
    elseif schemas !== nothing && namespaces !== nothing
        validate(schemas, namespaces)
    elseif graph !== nothing
        validate(graph)
    elseif schemas !== nothing
        validate(schemas)
    elseif namespaces !== nothing
        validate(namespaces)
    else
        return nothing
    end
    isvalid(report) && return report
    codes = Tuple(item.code for item in report.diagnostics)
    throw(ArgumentError("refusing to write invalid AH5 archive: $codes"))
end

function _blocks_interpretation(diagnostics)
    for diagnostic in diagnostics
        diagnostic.code in AH5_INTERPRETATION_BLOCKERS && return true
    end
    return false
end

function _validate_archive_profile!(diagnostics, profile::ArchiveProfile)
    _validate_profile_consistency!(diagnostics, profile)
    if profile.magic == AH5_MAGIC
        major = _profile_major(profile.profile_version)
        if major === nothing || major != _profile_major(AH5_PROFILE_VERSION)
            push!(diagnostics, error_diagnostic(
                :unsupported_profile_version,
                "AH5 profile version $(profile.profile_version) is not supported (expected $AH5_PROFILE_VERSION major)";
                profile_version = profile.profile_version,
                supported = AH5_PROFILE_VERSION,
            ))
        end
    end
    unknown = Symbol[]
    for feature in profile.required_features
        feature in AH5_SUPPORTED_FEATURES || push!(unknown, feature)
    end
    if !isempty(unknown)
        push!(diagnostics, error_diagnostic(
            :unsupported_required_feature,
            "AH5 archive requires unsupported features $(Tuple(unknown))";
            required_features = Tuple(unknown),
        ))
    end
    return diagnostics
end

function _validate_profile_consistency!(diagnostics, profile::ArchiveProfile)
    missing = Symbol[]
    for feature in profile.required_features
        feature in profile.features || push!(missing, feature)
    end
    if !isempty(missing)
        push!(diagnostics, error_diagnostic(
            :required_feature_missing,
            "AH5 required features $(Tuple(missing)) are not declared present";
            required_features = Tuple(missing),
        ))
    end
    _validate_roots!(diagnostics, profile.roots)
    return diagnostics
end

function _validate_roots!(diagnostics, roots::ArchiveProfileRoots)
    used = String[]
    for (name, path) in (
        (:namespaces, roots.namespaces),
        (:schemas, roots.schemas),
        (:history, roots.history),
        (:provenance, roots.provenance),
        (:externals, roots.externals),
    )
        stripped = String(strip(path))
        if isempty(stripped) || stripped == AH5_PROFILE_KEY ||
                stripped == "_types" || startswith(stripped, "_types/") ||
                occursin("//", stripped)
            push!(diagnostics, error_diagnostic(
                :invalid_archive_root,
                "AH5 $name root $(repr(path)) is not a usable inspectable path";
                root = name,
                path = path,
            ))
            continue
        end
        if stripped in used
            push!(diagnostics, error_diagnostic(
                :invalid_archive_root,
                "AH5 $name root $(repr(path)) collides with another inspectable path";
                root = name,
                path = path,
            ))
        else
            push!(used, stripped)
        end
    end
    return diagnostics
end

function validate(profile::ArchiveProfile)
    diagnostics = DiagnosticMessage[]
    if profile.magic != AH5_MAGIC
        push!(diagnostics, error_diagnostic(
            :not_ah5_archive,
            "in-file magic $(repr(profile.magic)) is not $AH5_MAGIC";
            magic = profile.magic,
        ))
    end
    _validate_archive_profile!(diagnostics, profile)
    return ValidationReport(
        :ah5_profile,
        isempty(diagnostics),
        diagnostics,
        (;
            archive_id = profile.archive_id,
            profile_version = profile.profile_version,
            package_version = profile.package_version,
        ),
    )
end

function validate(inspection::ArchiveInspection)
    return ValidationReport(
        :ah5_archive,
        inspection.identified && isempty(inspection.diagnostics),
        inspection.diagnostics,
        (;
            path = inspection.path,
            identified = inspection.identified,
            archive_id = inspection.profile === nothing ? nothing : inspection.profile.archive_id,
            schemas = length(inspection.schemas),
            namespaces = length(inspection.namespaces),
        ),
    )
end

function report(profile::ArchiveProfile)
    return ObjectReport(
        :ah5_profile,
        "AH5 profile $(profile.profile_version) archive $(profile.archive_id).",
        to_namedtuple(profile),
        DiagnosticMessage[],
        ArtifactRef[],
    )
end

function report(inspection::ArchiveInspection)
    id = inspection.profile === nothing ? "unidentified" : inspection.profile.archive_id
    return ObjectReport(
        :ah5_archive,
        inspection.identified ? "AH5 archive $id." : "File is not an AH5 archive.",
        to_namedtuple(inspection),
        inspection.diagnostics,
        ArtifactRef[],
    )
end

function readiness(inspection::ArchiveInspection, target::PipelineTarget)
    ok = inspection.identified && isempty(inspection.diagnostics)
    return ReadinessReport(
        :ah5_archive,
        target,
        ok && target.name === :inspect,
        inspection.diagnostics,
        (;
            identified = inspection.identified,
            target = target.name,
        ),
    )
end

to_namedtuple(roots::ArchiveProfileRoots) = (
    namespaces = roots.namespaces,
    schemas = roots.schemas,
    history = roots.history,
    provenance = roots.provenance,
    externals = roots.externals,
)

to_namedtuple(profile::ArchiveProfile) = (
    magic = profile.magic,
    profile_version = profile.profile_version,
    archive_id = profile.archive_id,
    created_at = profile.created_at,
    creator = profile.creator,
    features = profile.features,
    required_features = profile.required_features,
    roots = to_namedtuple(profile.roots),
    package_version = profile.package_version,
)

to_namedtuple(history::ArchiveHistorySummary) = (
    objects = history.objects,
    heads = history.heads,
    revisions = history.revisions,
    runs = history.runs,
    events = history.events,
    writes = history.writes,
    log_streams = history.log_streams,
    head_names = history.head_names,
)

to_namedtuple(prov::ArchiveProvenanceSummary) = (
    software_environments = prov.software_environments,
    execution_contexts = prov.execution_contexts,
)

to_namedtuple(inspection::ArchiveInspection) = (
    path = inspection.path,
    identified = inspection.identified,
    profile = inspection.profile === nothing ? nothing : to_namedtuple(inspection.profile),
    namespaces = Tuple(to_namedtuple.(inspection.namespaces)),
    schemas = Tuple(to_namedtuple.(inspection.schemas)),
    history = to_namedtuple(inspection.history),
    provenance = to_namedtuple(inspection.provenance),
    externals = Tuple(to_namedtuple.(inspection.externals)),
    diagnostics = Tuple(to_namedtuple.(inspection.diagnostics)),
)

function from_namedtuple(::Type{ArchiveProfileRoots}, nt)
    return ArchiveProfileRoots(;
        namespaces = String(nt.namespaces),
        schemas = String(nt.schemas),
        history = String(nt.history),
        provenance = String(nt.provenance),
        externals = String(nt.externals),
    )
end

function from_namedtuple(::Type{ArchiveProfile}, nt)
    return ArchiveProfile(;
        magic = String(nt.magic),
        profile_version = String(nt.profile_version),
        archive_id = String(nt.archive_id),
        created_at = String(nt.created_at),
        creator = String(nt.creator),
        features = _feature_tuple(nt.features),
        required_features = hasproperty(nt, :required_features) ?
            _feature_tuple(nt.required_features) : (),
        roots = from_namedtuple(ArchiveProfileRoots, nt.roots),
        package_version = String(nt.package_version),
    )
end

function from_namedtuple(::Type{ArchiveHistorySummary}, nt)
    return ArchiveHistorySummary(
        Int(nt.objects),
        Int(nt.heads),
        Int(nt.revisions),
        Int(nt.runs),
        Int(nt.events),
        Int(nt.writes),
        Int(nt.log_streams),
        Tuple(Symbol(name) for name in nt.head_names),
    )
end

function from_namedtuple(::Type{ArchiveProvenanceSummary}, nt)
    return ArchiveProvenanceSummary(
        Tuple(String(id) for id in nt.software_environments),
        Tuple(String(id) for id in nt.execution_contexts),
    )
end
