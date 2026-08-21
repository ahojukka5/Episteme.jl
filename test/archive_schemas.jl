# Embedded payload schemas (#39). No HDF5 and no JLD2 type-registry identity.

function _mesh_fields()
    return [
        SchemaField(
            LogicalArraySpec(:coordinates, LogicalType(:real; units = "m", frame = "box"), 2; shape = (3, nothing));
            required = true,
            support = "mesh",
            location = "vertex",
            documentation = "vertex coordinates",
        ),
        SchemaField(
            :geometry,
            LogicalType(:string);
            required = true,
            reference_target = Symbol("monge/box"),
            documentation = "owning geometry object",
        ),
    ]
end

function _field_fields()
    return [
        SchemaField(
            :name,
            LogicalType(:string);
            rules = (ValidationRule(:nonempty),),
            documentation = "field name",
        ),
        SchemaField(
            :values,
            LogicalType(:real; units = "1");
            rank = 1,
            shape = (nothing,),
            location = "cell",
        ),
    ]
end

function _mesh_def(; version = "1.0.0", compatibility = :exact_read, package_version = "0.4.0")
    schema = SchemaRef(:delone, "mesh", version)
    return SchemaDefinition(
        schema;
        namespace = ArchiveNamespace(:delone; package_uuid = UUID_DELONE, display_name = "Delone.jl"),
        compatibility = compatibility,
        fields = _mesh_fields(),
        documentation = "unstructured mesh",
        package_version = package_version,
    )
end

function _field_def(; version = "1.0.0", compatibility = :exact_read, replaces = nothing, replaced_by = nothing, migration = nothing)
    schema = SchemaRef(:oodi, "field", version)
    node = NodeSchema(
        schema_kind(schema),
        AttributeSchema(:name, :string; rules = (ValidationRule(:nonempty),)),
        AttributeSchema(:scale, :real; required = false, rules = (ValidationRule(:finite),)),
    )
    return SchemaDefinition(
        schema;
        namespace = ArchiveNamespace(:oodi; package_uuid = UUID_OODI, display_name = "Oodi.jl"),
        compatibility = compatibility,
        fields = _field_fields(),
        node_schema = node,
        documentation = "scalar field",
        package_version = "1.2.0",
        replaces = replaces,
        replaced_by = replaced_by,
        migration = migration,
    )
end

@testset "embedded schemas are self-describing without domain packages" begin
    mesh_v1 = _mesh_def()
    field_v1 = _field_def()
    field_v2 = _field_def(; version = "2.0.0")
    registry = SchemaRegistry([mesh_v1, field_v1, field_v2])
    @test isvalid(validate(mesh_v1))
    @test isvalid(validate(registry))
    @test isready(readiness(registry, PipelineTarget(:inspect)))
    @test !hasfield(SchemaDefinition, :julia_type)
    @test mesh_v1.schema != field_v1.schema
    @test field_v1.schema != field_v2.schema
    @test schema_kind(mesh_v1.schema) === Symbol("delone/mesh")
    @test schema_status(field_v1.schema, registry) === :exact_read
    @test schema_status(SchemaRef(:oodi, "field", "9.9.9"), registry) === :missing_schema

    listings = list_schemas(registry)
    @test [listing.schema for listing in listings] == [mesh_v1.schema, field_v1.schema, field_v2.schema]
    @test listings[1].field_names === (:coordinates, :geometry)
    coordinates = listings[1].fields[1]
    @test coordinates.name === :coordinates
    @test coordinates.element.kind === :real
    @test coordinates.element.units == "m"
    @test coordinates.element.frame == "box"
    @test coordinates.rank == 2
    @test coordinates.shape === (3, nothing)
    @test coordinates.support == "mesh"
    @test coordinates.location == "vertex"
    @test listings[1].fields[2].reference_target === Symbol("monge/box")
    @test listings[1].node_schema === nothing
    @test listings[2].has_node_schema
    field_only = only(list_schemas(SchemaRegistry([field_v1])))
    node = field_only.node_schema
    @test node !== nothing
    @test node.kind === Symbol("oodi/field")
    @test getfield.(node.attributes, :name) == [:name, :scale]
    @test node.attributes[1].value_kind === :string
    @test node.attributes[1].required
    @test only(node.attributes[1].rules).kind === :nonempty
    @test node.attributes[2].value_kind === :real
    @test !node.attributes[2].required
    @test only(node.attributes[2].rules).kind === :finite
    @test !node.allow_extra
    node_nt = to_namedtuple(field_only).node_schema
    @test node_nt.kind === Symbol("oodi/field")
    @test [attr.name for attr in node_nt.attributes] == [:name, :scale]
    @test node_nt.attributes[2].rules[1].kind === :finite
    @test to_namedtuple(listings[1]).package_version == "0.4.0"
    @test to_namedtuple(listings[1]).fields[1].element.units == "m"

    same_id_new_pkg = _mesh_def(; package_version = "9.9.9")
    @test same_id_new_pkg.schema == mesh_v1.schema
    @test same_id_new_pkg.package_version != mesh_v1.package_version

    catalog = known_schemas(registry)
    @test schema_status(field_v2.schema, catalog) === :exact_read
    @test length(catalog.schemas) == 3

    nt = to_namedtuple(registry)
    restored = from_namedtuple(SchemaRegistry, nt)
    @test isvalid(validate(restored))
    @test restored.entries[1].schema == mesh_v1.schema
    @test restored.entries[1].fields[1].element.units == "m"
    @test restored.entries[2].node_schema.kind === Symbol("oodi/field")
end

@testset "two schema revisions and two domains stay unambiguous in one archive" begin
    mesh_v1 = _mesh_def()
    field_v1 = _field_def()
    field_v2 = _field_def(; version = "2.0.0")
    registry = SchemaRegistry([mesh_v1, field_v1, field_v2])
    mesh = _obj(:delone, "mesh", ID_MESH, REV_1; uuid = UUID_DELONE)
    field_old = _obj(:oodi, "field", ID_FIELD, REV_2; uuid = UUID_OODI)
    field_new = ArchiveObject(
        ObjectId(ID_SPACE),
        RevisionId(REV_3);
        namespace = ArchiveNamespace(:oodi; package_uuid = UUID_OODI, display_name = "Oodi.jl"),
        kind = Symbol("oodi/field"),
        schema = SchemaRef(:oodi, "field", "2.0.0"),
    )
    graph = ArchiveGraph([mesh, field_old, field_new])
    @test isvalid(validate(graph, registry))
    used = list_schemas(graph, registry)
    @test length(used) == 3
    @test field_old.schema != field_new.schema
    @test field_old.kind == field_new.kind
end

@testset "missing, unsupported, corrupt, and payload-violating schemas are distinct" begin
    mesh_v1 = _mesh_def()
    unsupported = _field_def(; compatibility = :unsupported)
    migrating = _field_def(;
        version = "0.8.0",
        compatibility = :migration_required,
        migration = SchemaMigrationRef(
            SchemaRef(:oodi, "field", "0.8.0"),
            SchemaRef(:oodi, "field", "1.0.0");
            implementation_id = "oodi-field-0.8-to-1.0",
        ),
    )
    registry = SchemaRegistry([mesh_v1, unsupported, migrating])
    @test isvalid(validate(registry))

    missing = validate(
        ArchiveGraph([_obj(:delone, "volume", ID_VOL, REV_1)]),
        SchemaRegistry([mesh_v1]),
    )
    @test any(d -> d.code === :missing_schema, missing.diagnostics)

    blocked = validate(
        ArchiveGraph([_obj(:oodi, "field", ID_FIELD, REV_1; uuid = UUID_OODI)]),
        SchemaRegistry([unsupported]),
    )
    @test any(d -> d.code === :unsupported_schema, blocked.diagnostics)

    needs_migration = validate(
        ArchiveGraph([
            ArchiveObject(
                ObjectId(ID_FIELD),
                RevisionId(REV_1);
                namespace = ArchiveNamespace(:oodi; package_uuid = UUID_OODI),
                kind = Symbol("oodi/field"),
                schema = SchemaRef(:oodi, "field", "0.8.0"),
            ),
        ]),
        SchemaRegistry([migrating]),
    )
    @test any(d -> d.code === :migration_required, needs_migration.diagnostics)

    corrupt = SchemaDefinition(
        SchemaRef(:delone, "mesh", "1.0.0");
        namespace = ArchiveNamespace(:delone; package_uuid = UUID_DELONE),
        fields = SchemaField[],
    )
    @test any(d -> d.code === :corrupt_schema, validate(corrupt).diagnostics)
    mismatched_node = SchemaDefinition(
        SchemaRef(:oodi, "field", "1.0.0");
        namespace = ArchiveNamespace(:oodi; package_uuid = UUID_OODI),
        node_schema = NodeSchema(Symbol("delone/mesh")),
    )
    @test any(d -> d.code === :corrupt_schema, validate(mismatched_node).diagnostics)
    missing_mig = _field_def(; version = "0.7.0", compatibility = :migration_required)
    @test any(d -> d.code === :missing_migration_ref, validate(missing_mig).diagnostics)

    payload_ok = (; name = "u", values = [1.0, 2.0])
    @test isvalid(validate(payload_ok, unsupported))
    payload_bad = (; name = "", values = [1.0, 2.0])
    violation = validate(payload_bad, _field_def())
    @test !isvalid(violation)
    @test any(d -> d.code === :payload_schema_violation, violation.diagnostics)

    node_ok = SemanticNode(Symbol("oodi/field"), :u; name = "u", scale = 1.0)
    @test isvalid(validate(node_ok, _field_def()))
    node_bad = SemanticNode(Symbol("oodi/field"), :u; name = "", scale = Inf)
    @test !isvalid(validate(node_bad, _field_def()))

    ref_ok = (; coordinates = [0.0 1.0; 0.0 1.0; 0.0 1.0], geometry = ObjectId(ID_GEOM))
    @test isvalid(validate(ref_ok, mesh_v1))
    ref_bad = (; coordinates = [0.0 1.0; 0.0 1.0; 0.0 1.0], geometry = "not-an-id")
    @test any(
        d -> d.code === :payload_schema_violation && d.context.reason === :reference_target,
        validate(ref_bad, mesh_v1).diagnostics,
    )
    mixed = (; name = "u", values = Any[1.0, "bad"])
    @test any(
        d -> d.code === :payload_schema_violation && d.context.reason === :logical_type,
        validate(mixed, _field_def()).diagnostics,
    )
end

@testset "schema identity is not a Julia type or package version" begin
    v1 = _mesh_def(; package_version = "0.1.0")
    v1_other_pkg = _mesh_def(; package_version = "8.0.0")
    @test v1.schema == v1_other_pkg.schema
    duplicate = validate(SchemaRegistry([v1, v1_other_pkg]))
    @test any(d -> d.code === :duplicate_schema, duplicate.diagnostics)
    @test :julia_type ∉ keys(to_namedtuple(v1))
    @test report(v1).subject === Symbol("delone/mesh")
    @test occursin("1.0.0", report(SchemaRegistry([v1])).summary) ||
        occursin("embedded", lowercase(report(SchemaRegistry([v1])).summary))
    @test !isready(readiness(SchemaRegistry([v1]), PipelineTarget(:commit)))
end

@testset "schema namespaces follow #38 identity and aliases" begin
    stolen = SchemaDefinition(
        SchemaRef(:delone, "volume", "1.0.0");
        namespace = ArchiveNamespace(:delone; package_uuid = UUID_OODI, display_name = "NotDelone"),
        fields = _mesh_fields(),
    )
    conflict = validate(SchemaRegistry([_mesh_def(), stolen]))
    @test any(d -> d.code === :namespace_identity_conflict, conflict.diagnostics)

    delone_claim = NamespaceClaim(
        ArchiveNamespace(:delone; package_uuid = UUID_DELONE, display_name = "Delone.jl");
        role = :domain,
    )
    omitted = SchemaDefinition(
        SchemaRef(:delone, "mesh", "1.0.0");
        namespace = ArchiveNamespace(:delone; display_name = "Delone.jl"),
        fields = _mesh_fields(),
    )
    @test any(
        d -> d.code === :namespace_identity_missing,
        validate(SchemaRegistry([omitted]), NamespaceRegistry([delone_claim])).diagnostics,
    )
    @test isvalid(validate(SchemaRegistry([_mesh_def()]), NamespaceRegistry([delone_claim])))

    historical = SchemaDefinition(
        SchemaRef(:oodicore, "document", "1.0.0");
        namespace = ArchiveNamespace(
            :oodicore;
            package_uuid = EPISTEME_PACKAGE_UUID,
            display_name = "OodiCore.jl",
        ),
        node_schema = NodeSchema(Symbol("oodicore/document")),
    )
    aliases = NamespaceRegistry([
        NamespaceClaim(episteme_namespace(); role = :shared, aliases = (:oodicore,)),
        NamespaceClaim(
            ArchiveNamespace(:oodicore; package_uuid = EPISTEME_PACKAGE_UUID);
            role = :shared,
            status = :alias,
            canonical_id = EPISTEME_NAMESPACE,
        ),
    ])
    @test isvalid(validate(SchemaRegistry([historical]), aliases))
    graph = ArchiveGraph([
        ArchiveObject(
            ObjectId("doc-old"),
            RevisionId(REV_1);
            namespace = ArchiveNamespace(:oodicore; package_uuid = EPISTEME_PACKAGE_UUID),
            kind = Symbol("oodicore/document"),
            schema = historical.schema,
        ),
    ])
    @test isvalid(validate(graph, SchemaRegistry([historical]), aliases))
end

@testset "replacement and migration metadata cannot contradict itself" begin
    self_replaced = _field_def(; replaced_by = SchemaRef(:oodi, "field", "1.0.0"))
    @test any(d -> d.code === :corrupt_schema, validate(self_replaced).diagnostics)

    mismatched = _field_def(;
        version = "0.8.0",
        compatibility = :migration_required,
        replaced_by = SchemaRef(:oodi, "field", "2.0.0"),
        migration = SchemaMigrationRef(
            SchemaRef(:oodi, "field", "0.8.0"),
            SchemaRef(:oodi, "field", "1.0.0"),
        ),
    )
    @test any(d -> d.code === :corrupt_schema, validate(mismatched).diagnostics)

    old = _field_def(;
        version = "0.8.0",
        compatibility = :migration_required,
        replaced_by = SchemaRef(:oodi, "field", "1.0.0"),
        migration = SchemaMigrationRef(
            SchemaRef(:oodi, "field", "0.8.0"),
            SchemaRef(:oodi, "field", "1.0.0"),
        ),
    )
    new = _field_def(; version = "1.0.0", replaces = SchemaRef(:oodi, "field", "0.9.0"))
    reciprocal = validate(SchemaRegistry([old, new]))
    @test any(d -> d.code === :corrupt_schema, reciprocal.diagnostics)
    agreed = _field_def(; version = "1.0.0", replaces = SchemaRef(:oodi, "field", "0.8.0"))
    @test isvalid(validate(SchemaRegistry([old, agreed])))
end
