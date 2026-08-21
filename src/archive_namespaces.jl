# ---------------------------------------------------------------------------
# Package namespaces and reserved shared namespaces (#38)
#
# Logical identity, reservation, alias, and ownership rules. No HDF5 paths
# and no payload loading. Physical group spelling is issue #40.
# ---------------------------------------------------------------------------

"""
Stable short name of the shared Episteme namespace. Shared infrastructure
kinds are `episteme/*` and must not be claimed by a domain package.
"""
const EPISTEME_NAMESPACE = :episteme

"""
Julia package UUID for Episteme.jl. Namespace identity follows this UUID
across display-name or repository renames; the short name
[`EPISTEME_NAMESPACE`](@ref) is the current alias, not a second identity.
"""
const EPISTEME_PACKAGE_UUID = "7c15cd61-9c6a-4671-bc94-9960963998ac"

"""
Package namespace identifiers reserved for Episteme shared infrastructure.
Domain and extension packages must not claim these names.
"""
const RESERVED_SHARED_NAMESPACES = (EPISTEME_NAMESPACE,)

"""
Logical reserved archive areas. These are not package namespaces and not
HDF5 paths. Issue #40 chooses physical spelling for the AH5 profile.

A package may not register one of these names as its namespace `id`.
"""
const RESERVED_ARCHIVE_AREAS = (
    :profile,
    :provenance,
    :schemas,
    :revisions,
    :runs,
    :events,
    :heads,
    :objects,
    :content,
    :payloads,
)

const NAMESPACE_ROLES = (:shared, :domain, :extension)
const NAMESPACE_STATUSES = (:active, :deprecated, :alias)

is_reserved_shared_namespace(id::Symbol) = id in RESERVED_SHARED_NAMESPACES
is_reserved_archive_area(id::Symbol) = id in RESERVED_ARCHIVE_AREAS

owns_kind(namespace_id::Symbol, kind::Symbol) =
    startswith(String(kind), _kind_prefix(namespace_id))

"""
    episteme_namespace(; display_name="Episteme.jl")

Shared [`ArchiveNamespace`](@ref) for Episteme-owned objects and schemas.
`display_name` is a label; identity is [`EPISTEME_PACKAGE_UUID`](@ref).
"""
function episteme_namespace(; display_name::AbstractString = "Episteme.jl")
    return ArchiveNamespace(
        EPISTEME_NAMESPACE;
        package_uuid = EPISTEME_PACKAGE_UUID,
        display_name = display_name,
    )
end

"""
    NamespaceClaim(namespace; role=:domain, status=:active, canonical_id=nothing,
                   aliases=())

Declared ownership of one package or extension namespace.

`role` is `:shared` (only `:episteme`), `:domain`, or `:extension`.
Optional integrations use `:extension` and their own namespace rather
than mutating another package's schema.

`status` is `:active`, `:deprecated`, or `:alias`. Alias claims require
`canonical_id` of the live namespace and must share that package UUID
when both UUIDs are recorded.

`aliases` on an active claim lists former short names that still resolve
to this identity. Display-name and repository changes are not aliases;
they keep the same [`ArchiveNamespace.id`](@ref) and `package_uuid`.
"""
struct NamespaceClaim
    namespace::ArchiveNamespace
    role::Symbol
    status::Symbol
    canonical_id::Symbol
    aliases::Tuple{Vararg{Symbol}}
end

function NamespaceClaim(
    namespace::ArchiveNamespace;
    role::Symbol = :domain,
    status::Symbol = :active,
    canonical_id = nothing,
    aliases = (),
)
    role in NAMESPACE_ROLES || throw(ArgumentError(
        "unknown namespace role :$role (expected one of $NAMESPACE_ROLES)",
    ))
    status in NAMESPACE_STATUSES || throw(ArgumentError(
        "unknown namespace status :$status (expected one of $NAMESPACE_STATUSES)",
    ))
    alias_ids = _symbol_tuple(aliases, "aliases")
    namespace.id in alias_ids && throw(ArgumentError(
        "aliases must not include the claim's own namespace id :$(namespace.id)",
    ))
    cid = _claim_canonical_id(namespace.id, status, canonical_id)
    return NamespaceClaim(namespace, role, status, cid, alias_ids)
end

function _claim_canonical_id(id::Symbol, status::Symbol, canonical_id)
    if canonical_id === nothing
        status === :alias && throw(ArgumentError(
            "alias namespace claims require canonical_id",
        ))
        return id
    end
    canonical_id isa Symbol || throw(ArgumentError(
        "canonical_id must be a Symbol, got $(typeof(canonical_id))",
    ))
    if status === :alias
        canonical_id === id && throw(ArgumentError(
            "alias canonical_id must differ from namespace id :$id",
        ))
    elseif canonical_id !== id
        throw(ArgumentError(
            "non-alias canonical_id must equal namespace id :$id",
        ))
    end
    return canonical_id
end

"""
    NamespaceRegistry(claims=())

Registered namespace ownership used to list identities and to reject
claims on another package's namespace. Claims are data; this is not a
codec registry and not the embedded schema catalog (#39).
"""
struct NamespaceRegistry
    claims::Vector{NamespaceClaim}

    function NamespaceRegistry(claims = NamespaceClaim[])
        return new(_typed_vector(NamespaceClaim, claims, "namespace claims"))
    end
end

"""
    NamespaceListing

Inspection view of one namespace: identity, display metadata, role, and
the schema/object kinds observed without loading payloads.
"""
struct NamespaceListing
    namespace::ArchiveNamespace
    role::Symbol
    status::Symbol
    canonical_id::Symbol
    aliases::Tuple{Vararg{Symbol}}
    kinds::Tuple{Vararg{Symbol}}
    schema_ids::Tuple{Vararg{String}}
end

function ordered_claims(registry::NamespaceRegistry)
    return sort(registry.claims; by = _claim_sort_key)
end

_claim_sort_key(claim::NamespaceClaim) = (
    String(claim.namespace.id),
    claim.namespace.package_uuid,
    String(claim.status),
)

"""
    find_claim(registry, id) -> Union{NamespaceClaim,Nothing}

Claim whose current short name is `id`, not following aliases.
"""
function find_claim(registry::NamespaceRegistry, id::Symbol)
    for claim in ordered_claims(registry)
        claim.namespace.id === id && return claim
    end
    return nothing
end

"""
    resolve_namespace(registry, id) -> Union{NamespaceClaim,Nothing}

Canonical claim for `id`, following alias short names and `aliases`
listed on an active or deprecated claim.
"""
function resolve_namespace(registry::NamespaceRegistry, id::Symbol)
    direct = find_claim(registry, id)
    if direct !== nothing
        direct.status === :alias || return direct
        return find_claim(registry, direct.canonical_id)
    end
    for claim in ordered_claims(registry)
        claim.status === :alias && continue
        id in claim.aliases && return claim
    end
    return nothing
end

function _validate_object_namespace!(diagnostics, object::ArchiveObject)
    ns = object.namespace
    if is_reserved_archive_area(ns.id)
        push!(diagnostics, error_diagnostic(
            :reserved_archive_area_claimed,
            "namespace :$(ns.id) is a reserved archive area, not a package namespace";
            object_id = object.object_id.value,
            namespace = ns.id,
        ))
    end
    if is_reserved_shared_namespace(ns.id)
        uuid = ns.package_uuid
        if !isempty(uuid) && uuid != EPISTEME_PACKAGE_UUID
            push!(diagnostics, error_diagnostic(
                :reserved_namespace_claimed,
                "namespace :$(ns.id) is reserved for Episteme (UUID $EPISTEME_PACKAGE_UUID)";
                object_id = object.object_id.value,
                namespace = ns.id,
                package_uuid = uuid,
            ))
        end
    elseif startswith(String(object.kind), _kind_prefix(EPISTEME_NAMESPACE))
        push!(diagnostics, error_diagnostic(
            :reserved_kind_claimed,
            "kind $(object.kind) is reserved for namespace :$EPISTEME_NAMESPACE";
            object_id = object.object_id.value,
            kind = object.kind,
            namespace = ns.id,
        ))
    end
    return diagnostics
end

function _validate_namespace_identities!(
    diagnostics,
    objects;
    registry::Union{Nothing,NamespaceRegistry} = nothing,
)
    by_id = Dict{Symbol,Vector{String}}()
    by_uuid = Dict{String,Vector{Symbol}}()
    for object in objects
        ns = object.namespace
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
        _ids_share_canonical(registry, ids, uuid) && continue
        push!(diagnostics, error_diagnostic(
            :namespace_id_split,
            "package UUID $uuid is used as namespaces $(Tuple(ids)) without an alias";
            package_uuid = uuid,
            namespaces = Tuple(sort(ids; by = String)),
        ))
    end

    registry === nothing && return diagnostics
    for object in objects
        _validate_object_against_registry!(diagnostics, object, registry)
    end
    return diagnostics
end

function _ids_share_canonical(registry::Nothing, ids, uuid)
    return false
end

function _ids_share_canonical(registry::NamespaceRegistry, ids, uuid)
    canonicals = Symbol[]
    for id in ids
        claim = resolve_namespace(registry, id)
        claim === nothing && return false
        isempty(claim.namespace.package_uuid) ||
            claim.namespace.package_uuid == uuid || return false
        claim.canonical_id in canonicals || push!(canonicals, claim.canonical_id)
    end
    return length(canonicals) == 1
end

function _validate_object_against_registry!(diagnostics, object::ArchiveObject, registry::NamespaceRegistry)
    ns = object.namespace
    claimed = resolve_namespace(registry, ns.id)
    claimed === nothing && return diagnostics
    claimed_uuid = claimed.namespace.package_uuid
    if !isempty(claimed_uuid) && isempty(ns.package_uuid)
        push!(diagnostics, error_diagnostic(
            :namespace_identity_missing,
            "object namespace :$(ns.id) omits package UUID $claimed_uuid required by the registry";
            object_id = object.object_id.value,
            namespace = ns.id,
            registered_uuid = claimed_uuid,
        ))
    elseif !isempty(claimed_uuid) && claimed_uuid != ns.package_uuid
        push!(diagnostics, error_diagnostic(
            :namespace_identity_conflict,
            "object namespace :$(ns.id) UUID $(ns.package_uuid) does not match registered UUID $claimed_uuid";
            object_id = object.object_id.value,
            namespace = ns.id,
            package_uuid = ns.package_uuid,
            registered_uuid = claimed_uuid,
        ))
    end
    if claimed.canonical_id !== ns.id && find_claim(registry, ns.id) === nothing &&
            !(ns.id in claimed.aliases)
        push!(diagnostics, error_diagnostic(
            :namespace_id_split,
            "object namespace :$(ns.id) is not an alias of registered :$(claimed.canonical_id)";
            object_id = object.object_id.value,
            namespace = ns.id,
            canonical_id = claimed.canonical_id,
        ))
    end
    return diagnostics
end

function _is_episteme_identity(claim::NamespaceClaim)
    is_reserved_shared_namespace(claim.namespace.id) && return true
    is_reserved_shared_namespace(claim.canonical_id) && return true
    uuid = claim.namespace.package_uuid
    return !isempty(uuid) && uuid == EPISTEME_PACKAGE_UUID
end

function _validate_namespace_claim!(diagnostics, claim::NamespaceClaim)
    ns = claim.namespace
    if is_reserved_archive_area(ns.id)
        push!(diagnostics, error_diagnostic(
            :reserved_archive_area_claimed,
            "namespace :$(ns.id) is a reserved archive area, not a package namespace";
            namespace = ns.id,
        ))
    end
    if claim.status === :alias && is_reserved_shared_namespace(ns.id)
        push!(diagnostics, error_diagnostic(
            :reserved_namespace_claimed,
            "reserved namespace :$(ns.id) cannot be used as an alias of another identity";
            namespace = ns.id,
            canonical_id = claim.canonical_id,
        ))
    end
    for alias_id in claim.aliases
        if is_reserved_archive_area(alias_id)
            push!(diagnostics, error_diagnostic(
                :reserved_archive_area_claimed,
                "alias :$alias_id is a reserved archive area, not a package namespace";
                namespace = ns.id,
                alias = alias_id,
            ))
        end
        if is_reserved_shared_namespace(alias_id)
            push!(diagnostics, error_diagnostic(
                :reserved_namespace_claimed,
                "reserved namespace :$alias_id cannot be used as an alias of another identity";
                namespace = ns.id,
                alias = alias_id,
            ))
        end
    end
    if _is_episteme_identity(claim)
        if claim.role !== :shared
            push!(diagnostics, error_diagnostic(
                :reserved_namespace_claimed,
                "namespace :$(ns.id) is reserved for Episteme and must use role = :shared";
                namespace = ns.id,
                role = claim.role,
            ))
        end
        uuid = ns.package_uuid
        if !isempty(uuid) && uuid != EPISTEME_PACKAGE_UUID
            push!(diagnostics, error_diagnostic(
                :reserved_namespace_claimed,
                "namespace :$(ns.id) is reserved for Episteme (UUID $EPISTEME_PACKAGE_UUID)";
                namespace = ns.id,
                package_uuid = uuid,
            ))
        end
    elseif claim.role === :shared
        push!(diagnostics, error_diagnostic(
            :shared_namespace_role_mismatch,
            "role :shared is reserved for $(RESERVED_SHARED_NAMESPACES); got :$(ns.id)";
            namespace = ns.id,
            role = claim.role,
        ))
    end
    return diagnostics
end

function _register_alias_owner!(diagnostics, owners, alias_id::Symbol, owner_id::Symbol)
    previous = get(owners, alias_id, nothing)
    if previous === nothing
        owners[alias_id] = owner_id
        return diagnostics
    end
    previous === owner_id && return diagnostics
    push!(diagnostics, error_diagnostic(
        :namespace_identity_conflict,
        "alias :$alias_id is claimed by both :$previous and :$owner_id";
        alias = alias_id,
        namespace = owner_id,
        other_namespace = previous,
    ))
    return diagnostics
end

function _validate_namespace_registry!(diagnostics, registry::NamespaceRegistry)
    seen_ids = Dict{Symbol,NamespaceClaim}()
    for claim in ordered_claims(registry)
        _validate_namespace_claim!(diagnostics, claim)
        previous = get(seen_ids, claim.namespace.id, nothing)
        if previous === nothing
            seen_ids[claim.namespace.id] = claim
        else
            push!(diagnostics, error_diagnostic(
                :duplicate_namespace_claim,
                "namespace :$(claim.namespace.id) is claimed more than once";
                namespace = claim.namespace.id,
            ))
        end
    end

    by_uuid = Dict{String,Vector{Symbol}}()
    for claim in ordered_claims(registry)
        uuid = claim.namespace.package_uuid
        if !isempty(uuid)
            ids = get!(Vector{Symbol}, by_uuid, uuid)
            id = claim.status === :alias ? claim.canonical_id : claim.namespace.id
            id in ids || push!(ids, id)
        end
        if claim.status === :alias
            canonical = find_claim(registry, claim.canonical_id)
            if canonical === nothing
                push!(diagnostics, error_diagnostic(
                    :namespace_alias_unresolved,
                    "alias :$(claim.namespace.id) names unknown canonical :$(claim.canonical_id)";
                    namespace = claim.namespace.id,
                    canonical_id = claim.canonical_id,
                ))
            elseif canonical.status === :alias
                push!(diagnostics, error_diagnostic(
                    :namespace_alias_not_canonical,
                    "alias :$(claim.namespace.id) names :$(claim.canonical_id) which is itself an alias";
                    namespace = claim.namespace.id,
                    canonical_id = claim.canonical_id,
                ))
            else
                other = canonical.namespace.package_uuid
                if !isempty(other) && !isempty(uuid) && uuid != other
                    push!(diagnostics, error_diagnostic(
                        :namespace_alias_uuid_mismatch,
                        "alias :$(claim.namespace.id) UUID $uuid does not match :$(canonical.namespace.id) UUID $other";
                        namespace = claim.namespace.id,
                        canonical_id = canonical.namespace.id,
                        package_uuid = uuid,
                        registered_uuid = other,
                    ))
                end
                if claim.role !== canonical.role
                    push!(diagnostics, error_diagnostic(
                        :namespace_alias_role_mismatch,
                        "alias :$(claim.namespace.id) role :$(claim.role) does not match :$(canonical.namespace.id) role :$(canonical.role)";
                        namespace = claim.namespace.id,
                        canonical_id = canonical.namespace.id,
                        role = claim.role,
                        registered_role = canonical.role,
                    ))
                end
            end
        end
    end

    alias_owners = Dict{Symbol,Symbol}()
    for claim in ordered_claims(registry)
        if claim.status === :alias
            _register_alias_owner!(
                diagnostics,
                alias_owners,
                claim.namespace.id,
                claim.canonical_id,
            )
        else
            for alias_id in claim.aliases
                _register_alias_owner!(
                    diagnostics,
                    alias_owners,
                    alias_id,
                    claim.namespace.id,
                )
            end
        end
    end
    for (alias_id, owner_id) in alias_owners
        other = find_claim(registry, alias_id)
        other === nothing && continue
        if other.status === :alias
            other.canonical_id === owner_id && continue
        elseif other.namespace.id === owner_id
            continue
        end
        push!(diagnostics, error_diagnostic(
            :namespace_identity_conflict,
            "alias :$alias_id of :$owner_id collides with another claim";
            namespace = owner_id,
            alias = alias_id,
        ))
    end

    for (uuid, ids) in by_uuid
        length(ids) <= 1 && continue
        push!(diagnostics, error_diagnostic(
            :namespace_id_split,
            "package UUID $uuid is registered as namespaces $(Tuple(ids)) without a shared canonical id";
            package_uuid = uuid,
            namespaces = Tuple(sort(ids; by = String)),
        ))
    end
    return diagnostics
end

function validate(claim::NamespaceClaim)
    diagnostics = DiagnosticMessage[]
    _validate_namespace_claim!(diagnostics, claim)
    return ValidationReport(
        :namespace_claim,
        isempty(diagnostics),
        diagnostics,
        (;
            namespace = claim.namespace.id,
            role = claim.role,
            status = claim.status,
        ),
    )
end

function validate(registry::NamespaceRegistry)
    diagnostics = DiagnosticMessage[]
    _validate_namespace_registry!(diagnostics, registry)
    return ValidationReport(
        :namespace_registry,
        isempty(diagnostics),
        diagnostics,
        (; claims = length(registry.claims)),
    )
end

function validate(graph::ArchiveGraph, registry::NamespaceRegistry)
    diagnostics = DiagnosticMessage[]
    _validate_archive_graph!(diagnostics, graph; namespace_registry = registry)
    _validate_namespace_registry!(diagnostics, registry)
    return ValidationReport(
        :archive_graph,
        isempty(diagnostics),
        diagnostics,
        (; namespaces = length(list_namespaces(graph, registry))),
    )
end

function report(claim::NamespaceClaim)
    return ObjectReport(
        :namespace_claim,
        "Namespace claim :$(claim.namespace.id) ($(claim.role)/$(claim.status)).",
        to_namedtuple(claim),
        DiagnosticMessage[],
        ArtifactRef[],
    )
end

function report(registry::NamespaceRegistry)
    return ObjectReport(
        :namespace_registry,
        "Namespace registry with $(length(registry.claims)) claims.",
        (;
            claims = length(registry.claims),
            namespaces = Tuple(claim.namespace.id for claim in ordered_claims(registry)),
        ),
        DiagnosticMessage[],
        ArtifactRef[],
    )
end

function report(listing::NamespaceListing)
    return ObjectReport(
        :namespace_listing,
        "Namespace :$(listing.namespace.id) with $(length(listing.kinds)) kinds.",
        to_namedtuple(listing),
        DiagnosticMessage[],
        ArtifactRef[],
    )
end

function readiness(registry::NamespaceRegistry, target::PipelineTarget)
    target.name === :inspect || return ReadinessReport(
        :namespace_registry,
        target,
        false,
        [error_diagnostic(
            :unsupported_target,
            "namespace registry readiness target :$(target.name) is not :inspect";
            target = target.name,
        )],
        (; claims = length(registry.claims)),
    )
    report = validate(registry)
    return ReadinessReport(
        :namespace_registry,
        target,
        isvalid(report),
        report.diagnostics,
        (; claims = length(registry.claims)),
    )
end

"""
    list_namespaces(source, registry=nothing) -> Vector{NamespaceListing}

Generic namespace inspection from envelope metadata only. Payloads are
never loaded. `source` may be an [`ArchiveGraph`](@ref), a vector of
[`ArchiveObject`](@ref)s, or a [`RevisionManifest`](@ref).
"""
function list_namespaces(graph::ArchiveGraph, registry::Union{Nothing,NamespaceRegistry} = nothing)
    return list_namespaces(graph.objects, registry)
end

function list_namespaces(
    manifest::RevisionManifest,
    registry::Union{Nothing,NamespaceRegistry} = nothing,
)
    objects = ArchiveObject[]
    for entry in manifest.entries
        entry.object isa ArchiveObject && push!(objects, entry.object)
    end
    return list_namespaces(objects, registry)
end

function list_namespaces(
    objects,
    registry::Union{Nothing,NamespaceRegistry} = nothing,
)
    grouped = Dict{Symbol,_NamespaceAccumulator}()
    for object in objects
        object isa ArchiveObject || throw(ArgumentError(
            "namespace listing sources must contain ArchiveObject values",
        ))
        acc = get!(() -> _NamespaceAccumulator(object.namespace), grouped, object.namespace.id)
        _accumulate_namespace!(acc, object.namespace, object.kind, object.schema.schema_id)
    end

    if registry !== nothing
        for claim in ordered_claims(registry)
            acc = get!(
                grouped,
                claim.namespace.id,
                _NamespaceAccumulator(claim.namespace),
            )
            _accumulate_claim!(acc, claim)
        end
    end

    listings = NamespaceListing[]
    for id in sort!(collect(keys(grouped)); by = String)
        push!(listings, _finish_listing(grouped[id], id, registry))
    end
    return listings
end

mutable struct _NamespaceAccumulator
    namespace::ArchiveNamespace
    kinds::Vector{Symbol}
    schema_ids::Vector{String}
    role::Union{Nothing,Symbol}
    status::Union{Nothing,Symbol}
    canonical_id::Union{Nothing,Symbol}
    aliases::Vector{Symbol}
end

function _NamespaceAccumulator(ns::ArchiveNamespace)
    return _NamespaceAccumulator(ns, Symbol[], String[], nothing, nothing, nothing, Symbol[])
end

function _accumulate_namespace!(acc::_NamespaceAccumulator, ns::ArchiveNamespace, kind::Symbol, schema_id::AbstractString)
    if isempty(acc.namespace.package_uuid) && !isempty(ns.package_uuid)
        acc.namespace = ns
    elseif acc.namespace.display_name < ns.display_name
        acc.namespace = ArchiveNamespace(
            acc.namespace.id,
            isempty(acc.namespace.package_uuid) ? ns.package_uuid : acc.namespace.package_uuid,
            ns.display_name,
        )
    end
    kind in acc.kinds || push!(acc.kinds, kind)
    sid = String(schema_id)
    sid in acc.schema_ids || push!(acc.schema_ids, sid)
    return acc
end

function _accumulate_claim!(acc::_NamespaceAccumulator, claim::NamespaceClaim)
    acc.role = claim.role
    acc.status = claim.status
    acc.canonical_id = claim.canonical_id
    for alias_id in claim.aliases
        alias_id in acc.aliases || push!(acc.aliases, alias_id)
    end
    if !isempty(claim.namespace.display_name) || !isempty(claim.namespace.package_uuid)
        acc.namespace = ArchiveNamespace(
            acc.namespace.id;
            package_uuid = isempty(claim.namespace.package_uuid) ?
                acc.namespace.package_uuid : claim.namespace.package_uuid,
            display_name = isempty(claim.namespace.display_name) ?
                acc.namespace.display_name : claim.namespace.display_name,
        )
    end
    return acc
end

function _finish_listing(acc::_NamespaceAccumulator, id::Symbol, registry)
    role = acc.role
    status = acc.status
    canonical = acc.canonical_id
    aliases = acc.aliases
    if registry !== nothing
        resolved = resolve_namespace(registry, id)
        if resolved !== nothing
            role === nothing && (role = resolved.role)
            status === nothing && (status = id === resolved.namespace.id ? resolved.status : :alias)
            canonical === nothing && (canonical = resolved.canonical_id)
            if id !== resolved.namespace.id
                id in aliases || push!(aliases, id)
            end
            for alias_id in resolved.aliases
                alias_id in aliases || push!(aliases, alias_id)
            end
        end
    end
    role === nothing && (role = is_reserved_shared_namespace(id) ? :shared : :domain)
    status === nothing && (status = :active)
    canonical === nothing && (canonical = id)
    sort!(acc.kinds; by = String)
    sort!(acc.schema_ids)
    sort!(aliases; by = String)
    return NamespaceListing(
        acc.namespace,
        role,
        status,
        canonical,
        Tuple(aliases),
        Tuple(acc.kinds),
        Tuple(acc.schema_ids),
    )
end

to_namedtuple(claim::NamespaceClaim) = (
    namespace = to_namedtuple(claim.namespace),
    role = claim.role,
    status = claim.status,
    canonical_id = claim.canonical_id,
    aliases = claim.aliases,
)

to_namedtuple(registry::NamespaceRegistry) = (
    claims = Tuple(to_namedtuple.(ordered_claims(registry))),
)

to_namedtuple(listing::NamespaceListing) = (
    id = listing.namespace.id,
    package_uuid = listing.namespace.package_uuid,
    display_name = listing.namespace.display_name,
    role = listing.role,
    status = listing.status,
    canonical_id = listing.canonical_id,
    aliases = listing.aliases,
    kinds = listing.kinds,
    schema_ids = listing.schema_ids,
)

function from_namedtuple(::Type{NamespaceListing}, nt)
    return NamespaceListing(
        ArchiveNamespace(
            Symbol(nt.id);
            package_uuid = String(nt.package_uuid),
            display_name = String(nt.display_name),
        ),
        Symbol(nt.role),
        Symbol(nt.status),
        Symbol(nt.canonical_id),
        Tuple(Symbol(id) for id in nt.aliases),
        Tuple(Symbol(kind) for kind in nt.kinds),
        Tuple(String(id) for id in nt.schema_ids),
    )
end
