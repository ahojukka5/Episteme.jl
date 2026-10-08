# In-memory semantic schema migration chains (#103 / parent #41).

function _samples_fields()
    return [
        SchemaField(
            :name,
            LogicalType(:string);
            rules = (ValidationRule(:nonempty),),
            documentation = "field name",
        ),
        SchemaField(
            :samples,
            LogicalType(:real; units = "1");
            rank = 1,
            shape = (nothing,),
            location = "cell",
        ),
    ]
end

function _field_schema(version; fields = _field_fields(), compatibility = :exact_read, migration = nothing)
    schema = SchemaRef(:oodi, "field", version)
    return SchemaDefinition(
        schema;
        namespace = ArchiveNamespace(:oodi; package_uuid = UUID_OODI, display_name = "Oodi.jl"),
        compatibility = compatibility,
        fields = fields,
        documentation = "scalar field $version",
        package_version = "1.2.0",
        replaced_by = migration === nothing ? nothing : migration.target,
        migration = migration,
    )
end

function _field_object(revision, schema; content = "field-bytes")
    return _obj(
        :oodi,
        "field",
        ID_FIELD,
        revision;
        version = schema.version,
        content = content,
        uuid = UUID_OODI,
    )
end

import Episteme: migrate_payload

function migrate_payload(::Val{:toy_field_v1_v2}, payload::NamedTuple, ::SchemaMigrationStep)
    return (; name = payload.name, samples = payload.values)
end

function migrate_payload(::Val{:toy_field_v2_v3}, payload::NamedTuple, ::SchemaMigrationStep)
    return payload
end

function migrate_payload(::Val{:toy_field_v1_v3}, payload::NamedTuple, ::SchemaMigrationStep)
    return (; name = payload.name, samples = payload.values)
end

function migrate_payload(::Val{:toy_field_metadata}, payload::NamedTuple, ::SchemaMigrationStep)
    return payload
end

@testset "semantic migration plans resolve unique chains" begin
    v1 = SchemaRef(:oodi, "field", "1.0.0")
    v2 = SchemaRef(:oodi, "field", "2.0.0")
    v3 = SchemaRef(:oodi, "field", "3.0.0")
    chain = SchemaMigrationRegistry([
        SchemaMigrationStep(v1, v2; implementation_id = "toy_field_v1_v2"),
        SchemaMigrationStep(v2, v3; implementation_id = "toy_field_v2_v3", rewrite_payload = false),
    ])
    identity = plan_migration(v1, v1, chain)
    @test isvalid(identity)
    @test identity.status === :identity
    @test !identity.rewrite_payload
    @test isready(readiness(identity, PipelineTarget(:migrate)))

    direct = plan_migration(v1, v2, chain)
    @test isvalid(direct)
    @test direct.status === :direct
    @test direct.rewrite_payload

    chained = plan_migration(v1, v3, chain)
    @test isvalid(chained)
    @test chained.status === :chain
    @test length(chained.steps) == 2
    @test chained.rewrite_payload
    adjacency = chain.adjacency
    plan_migration(v1, v3, chain)
    @test chain.adjacency === adjacency

    missing = plan_migration(v1, SchemaRef(:oodi, "field", "9.0.0"), chain)
    @test !isvalid(missing)
    @test missing.status === :unsupported
    @test any(d -> d.code === :unsupported_migration, missing.diagnostics)
    @test !isready(readiness(missing, PipelineTarget(:migrate)))
end

@testset "ambiguous and unsupported migrations fail before output" begin
    v1 = SchemaRef(:oodi, "field", "1.0.0")
    v2 = SchemaRef(:oodi, "field", "2.0.0")
    v3 = SchemaRef(:oodi, "field", "3.0.0")
    @test_throws ArgumentError SchemaMigrationRegistry([
        SchemaMigrationStep(v1, v2; implementation_id = "toy_field_v1_v2"),
        SchemaMigrationStep(v1, v2; implementation_id = "other_impl"),
    ])
    diamond = SchemaMigrationRegistry([
        SchemaMigrationStep(v1, v2; implementation_id = "toy_field_v1_v2"),
        SchemaMigrationStep(v1, v3; implementation_id = "toy_field_v1_v3"),
        SchemaMigrationStep(v2, SchemaRef(:oodi, "field", "4.0.0"); implementation_id = "toy_field_v2_v3"),
        SchemaMigrationStep(v3, SchemaRef(:oodi, "field", "4.0.0"); implementation_id = "toy_field_v2_v3"),
    ])
    v4 = SchemaRef(:oodi, "field", "4.0.0")
    ambiguous = plan_migration(v1, v4, diamond)
    @test !isvalid(ambiguous)
    @test ambiguous.status === :ambiguous
    @test any(d -> d.code === :ambiguous_migration, ambiguous.diagnostics)

    @test_throws ArgumentError SchemaMigrationStep(v1, v1; implementation_id = "loop")
    @test_throws ArgumentError SchemaMigrationStep(
        v1, v2; implementation_id = "toy_field_v1_v2", axis = :julia_representation,
    )
end

@testset "migration registries refuse every directed cycle" begin
    refs = [SchemaRef(:example, "record", string(i, ".0.0")) for i in 1:4]
    edge(a, b) = SchemaMigrationStep(a, b; implementation_id = "not_loaded")
    two_cycle = [edge(refs[1], refs[2]), edge(refs[2], refs[1])]
    three_cycle = [edge(refs[1], refs[2]), edge(refs[2], refs[3]),
        edge(refs[3], refs[1])]
    @test_throws ArgumentError SchemaMigrationRegistry(two_cycle)
    @test_throws ArgumentError SchemaMigrationRegistry(reverse(two_cycle))
    @test_throws ArgumentError SchemaMigrationRegistry(three_cycle)
    @test_throws ArgumentError SchemaMigrationRegistry(
        [edge(refs[3], refs[4]); two_cycle],
    )

    # Reconstruction of portable declarations still uses the checked constructor.
    declarations = to_namedtuple.(two_cycle)
    restored = [SchemaMigrationStep(
        SchemaRef(row.source.namespace_id, row.source.schema_id, row.source.version),
        SchemaRef(row.target.namespace_id, row.target.schema_id, row.target.version);
        implementation_id = row.implementation_id,
        axis = row.axis,
        rewrite_payload = row.rewrite_payload,
        required_package = row.required_package,
    ) for row in declarations]
    @test_throws ArgumentError SchemaMigrationRegistry(restored)

    # Shared version labels in different namespaces/schema ids are distinct vertices.
    other = SchemaRef(:other, "record", "1.0.0")
    other_kind = SchemaRef(:example, "other", "1.0.0")
    distinct = SchemaMigrationRegistry([
        edge(refs[1], refs[2]), edge(refs[2], other), edge(other, other_kind),
    ])
    @test plan_migration(refs[1], other_kind, distinct).status === :chain
    @test length(plan_migration(refs[1], other_kind, distinct).steps) == 3

    converging = SchemaMigrationRegistry([
        edge(refs[1], refs[2]), edge(refs[1], refs[3]),
        edge(refs[2], refs[4]), edge(refs[3], refs[4]),
    ])
    @test plan_migration(refs[1], refs[2], converging).status === :direct
    @test plan_migration(refs[1], refs[4], converging).status === :ambiguous
    @test isvalid(plan_migration(refs[1], refs[1], SchemaMigrationRegistry([])))

    # No recursion-depth dependence for long valid chains or their closing edge.
    long_refs = [SchemaRef(:example, "long", string(i)) for i in 1:10_000]
    long_steps = [edge(long_refs[i], long_refs[i + 1]) for i in 1:9_999]
    long_plan = plan_migration(first(long_refs), last(long_refs),
        SchemaMigrationRegistry(long_steps))
    @test isvalid(long_plan)
    @test length(long_plan.steps) == 9_999
    @test_throws ArgumentError SchemaMigrationRegistry(
        [long_steps; edge(last(long_refs), first(long_refs))],
    )

    # The SchemaRegistry admission route checks its embedded migration edges too.
    v1, v2 = SchemaRef(:oodi, "field", "1.0.0"), SchemaRef(:oodi, "field", "2.0.0")
    definitions = SchemaRegistry([
        _field_schema("1.0.0"; migration = SchemaMigrationRef(v1, v2;
            implementation_id = "not_loaded")),
        _field_schema("2.0.0"; migration = SchemaMigrationRef(v2, v1;
            implementation_id = "not_loaded")),
    ])
    @test_throws ArgumentError SchemaMigrationRegistry(definitions)
end

@testset "toy v1 field migrates to v2 without mutating the source" begin
    v1 = _field_schema(
        "1.0.0";
        compatibility = :migration_required,
        migration = SchemaMigrationRef(
            SchemaRef(:oodi, "field", "1.0.0"),
            SchemaRef(:oodi, "field", "2.0.0");
            implementation_id = "toy_field_v1_v2",
        ),
    )
    v2 = _field_schema("2.0.0"; fields = _samples_fields())
    schemas = SchemaRegistry([v1, v2])
    migrations = SchemaMigrationRegistry(schemas)
    source = _field_object(REV_1, v1.schema; content = "field-v1")
    snapshot = to_namedtuple(source)
    payload = (; name = "psi", values = [1.0, 2.0, 3.0])
    result = migrate_object(
        source,
        payload,
        v2.schema,
        migrations;
        schemas = schemas,
        revision_id = RevisionId(REV_2),
    )
    @test isvalid(result)
    @test result.source_unchanged
    @test to_namedtuple(source) == snapshot
    @test result.object !== source
    @test result.object.object_id == source.object_id
    @test result.object.revision_id == RevisionId(REV_2)
    @test result.source_revision_id == source.revision_id
    @test result.source_schema == v1.schema
    @test result.target_schema == v2.schema
    @test result.payload == (; name = "psi", samples = [1.0, 2.0, 3.0])
    @test result.object.content_id != source.content_id
    @test result.object.content_id == canonical_content_id(result.payload)
    @test isvalid(validate(result.payload, v2))
    @test RevisionRecord(RevisionId(REV_2); parents = [RevisionId(REV_1)]).parents ==
        [RevisionId(REV_1)]
end

@testset "metadata-only migration reuses ContentId" begin
    v1 = _field_schema("1.0.0"; compatibility = :migration_required)
    v2 = _field_schema("1.1.0"; compatibility = :exact_read)
    schemas = SchemaRegistry([v1, v2])
    migrations = SchemaMigrationRegistry([
        SchemaMigrationStep(
            v1.schema,
            v2.schema;
            implementation_id = "toy_field_metadata",
            rewrite_payload = false,
            required_package = "Oodi.jl",
        ),
    ])
    source = _field_object(REV_1, v1.schema; content = "same-logical-bytes")
    payload = (; name = "psi", values = [1.0, 2.0])
    result = migrate_object(
        source,
        payload,
        v2.schema,
        migrations;
        schemas = schemas,
        revision_id = RevisionId(REV_2),
    )
    @test isvalid(result)
    @test !result.plan.rewrite_payload
    @test result.payload == payload
    @test result.object.content_id == source.content_id
    @test result.object.schema == v2.schema
end

@testset "chain and direct migrations agree on canonical payload identity" begin
    v1 = _field_schema("1.0.0")
    v2 = _field_schema("2.0.0"; fields = _samples_fields())
    v3 = _field_schema("3.0.0"; fields = _samples_fields())
    schemas = SchemaRegistry([v1, v2, v3])
    chained = SchemaMigrationRegistry([
        SchemaMigrationStep(v1.schema, v2.schema; implementation_id = "toy_field_v1_v2"),
        SchemaMigrationStep(v2.schema, v3.schema; implementation_id = "toy_field_v2_v3", rewrite_payload = false),
    ])
    direct = SchemaMigrationRegistry([
        SchemaMigrationStep(v1.schema, v3.schema; implementation_id = "toy_field_v1_v3"),
    ])
    source = _field_object(REV_1, v1.schema)
    payload = (; name = "psi", values = [4.0, 5.0])
    via_chain = migrate_object(source, payload, v3.schema, chained; schemas = schemas, revision_id = RevisionId(REV_2))
    via_direct = migrate_object(source, payload, v3.schema, direct; schemas = schemas, revision_id = RevisionId(REV_3))
    @test isvalid(via_chain)
    @test isvalid(via_direct)
    @test via_chain.payload == via_direct.payload
    @test canonical_content_id(via_chain.payload) == canonical_content_id(via_direct.payload)
    @test via_chain.object.content_id == via_direct.object.content_id
end

@testset "missing required fields and implementations fail closed" begin
    v1 = _field_schema("1.0.0")
    v2 = _field_schema("2.0.0"; fields = _samples_fields())
    schemas = SchemaRegistry([v1, v2])
    missing_impl = SchemaMigrationRegistry([
        SchemaMigrationStep(
            v1.schema,
            v2.schema;
            implementation_id = "not_loaded",
            required_package = "Oodi.jl",
        ),
    ])
    source = _field_object(REV_1, v1.schema)
    payload = (; name = "psi", values = [1.0])
    unloaded = migrate_object(
        source, payload, v2.schema, missing_impl;
        schemas = schemas, revision_id = RevisionId(REV_2),
    )
    @test !isvalid(unloaded)
    @test unloaded.object === nothing
    @test source.schema == v1.schema
    @test any(d -> d.code === :migration_implementation_missing, unloaded.diagnostics)
    @test any(d -> d.context.required_package == "Oodi.jl", unloaded.diagnostics)

    loaded = SchemaMigrationRegistry([
        SchemaMigrationStep(v1.schema, v2.schema; implementation_id = "toy_field_v1_v2"),
    ])
    incomplete = migrate_object(
        source,
        (; name = "psi"),
        v2.schema,
        loaded;
        schemas = schemas,
        revision_id = RevisionId(REV_2),
    )
    @test !isvalid(incomplete)
    @test incomplete.object === nothing
    @test any(d -> d.code === :payload_schema_violation, incomplete.diagnostics)
end

@testset "semantic migration is not a JLD2 representation upgrade" begin
    @test MIGRATION_AXES === (:semantic,)
    @test :julia_representation ∉ MIGRATION_AXES
    v1 = SchemaRef(:oodi, "field", "1.0.0")
    v2 = SchemaRef(:oodi, "field", "2.0.0")
    step = SchemaMigrationStep(v1, v2; implementation_id = "toy_field_v1_v2")
    @test step.axis === :semantic
    @test !hasfield(SchemaMigrationStep, :julia_type)
    @test !hasfield(MigrationPlan, :jld2_upgrade)
end

function migrate_payload(::Val{:mutate_nested_values}, payload::NamedTuple, ::SchemaMigrationStep)
    payload.values[1][1] += 10.0
    return payload
end

function migrate_payload(::Val{:mutate_then_missing}, payload::NamedTuple, ::SchemaMigrationStep)
    payload.values[1][1] += 100.0
    return missing
end

function migrate_payload(::Val{:mutate_then_invalid}, payload::NamedTuple, ::SchemaMigrationStep)
    payload.values[1][1] += 100.0
    return (; name = payload.name)
end

@testset "migration owns nested payload arrays on success and rejection" begin
    fields = [
        SchemaField(:name, LogicalType(:string)),
        SchemaField(:values, LogicalType(:real); rank = 1,
            shape = (nothing,), cardinality = :many),
    ]
    v1, v2, v3 = [_field_schema(v; fields) for v in ("1.0.0", "2.0.0", "3.0.0")]
    schemas = SchemaRegistry([v1, v2, v3])
    source = _field_object(REV_1, v1.schema)
    envelope = to_namedtuple(source)
    payload = (; name = "nested", values = [[1.0, 2.0], [3.0]])
    original = deepcopy(payload)
    function apply_steps(steps, target)
        migrate_object(source, payload, target, SchemaMigrationRegistry(steps);
            schemas, revision_id = RevisionId(REV_2))
    end
    first_step = SchemaMigrationStep(v1.schema, v2.schema;
        implementation_id = "mutate_nested_values")
    success = apply_steps([first_step], v2.schema)
    @test isvalid(success)
    @test success.source_unchanged
    @test payload == original
    @test to_namedtuple(source) == envelope
    @test success.payload.values == [[11.0, 2.0], [3.0]]
    @test success.payload.values !== payload.values
    @test success.payload.values[2] !== payload.values[2]
    @test success.object.content_id == canonical_content_id(success.payload)
    success.payload.values[2][1] = 99.0
    @test payload == original

    chain = apply_steps([first_step, SchemaMigrationStep(v2.schema, v3.schema;
        implementation_id = "mutate_nested_values")], v3.schema)
    @test isvalid(chain)
    @test chain.payload.values == [[21.0, 2.0], [3.0]]
    @test payload == original

    for implementation in ("mutate_then_missing", "mutate_then_invalid")
        rejected = apply_steps([first_step, SchemaMigrationStep(v2.schema, v3.schema;
            implementation_id = implementation)], v3.schema)
        @test !isvalid(rejected)
        @test rejected.source_unchanged
        @test rejected.payload === nothing
        @test rejected.object === nothing
        @test payload == original
        @test to_namedtuple(source) == envelope
    end

    metadata = apply_steps([SchemaMigrationStep(v1.schema, v2.schema;
        implementation_id = "mutate_nested_values", rewrite_payload = false)], v2.schema)
    @test !isvalid(metadata)
    @test metadata.payload === nothing
    @test metadata.object === nothing
    @test payload == original
    @test any(d -> d.code === :migration_rewrote_metadata_only, metadata.diagnostics)

    mixed = apply_steps([first_step, SchemaMigrationStep(v2.schema, v3.schema;
        implementation_id = "mutate_nested_values", rewrite_payload = false)], v3.schema)
    @test !isvalid(mixed)
    @test mixed.object === nothing
    @test payload == original
    @test any(d -> d.code === :migration_rewrote_metadata_only, mixed.diagnostics)
end
