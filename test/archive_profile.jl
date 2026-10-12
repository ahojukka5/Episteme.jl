# AH5 profile, JLD2 writer, and generic inspector (#40). No HDF5.jl.

using JLD2

@testset "JLD2-created AH5 archives are identified from in-file metadata" begin
    mktempdir() do dir
        path = joinpath(dir, "study.ah5")
        graph = ArchiveGraph([
            _obj(
                :delone, "mesh", ID_MESH, REV_1;
                uuid = UUID_DELONE,
                provenance = ProvenanceRefs(;
                    software_environment = SoftwareEnvironmentId("sw-delone"),
                    execution_context = ExecutionContextId("ctx-1"),
                ),
            ),
            _obj(:oodi, "field", ID_FIELD, REV_1; uuid = UUID_OODI),
        ]; heads = [WorkflowHead(WorkflowHeadId("head-1"), :main, RevisionId(REV_1))])
        namespaces = NamespaceRegistry([
            NamespaceClaim(
                ArchiveNamespace(:delone; package_uuid = UUID_DELONE, display_name = "Delone.jl");
                role = :domain,
            ),
            NamespaceClaim(
                ArchiveNamespace(:oodi; package_uuid = UUID_OODI, display_name = "Oodi.jl");
                role = :domain,
            ),
        ])
        schemas = SchemaRegistry([_mesh_def(), _field_def()])
        externals = [ExternalRequirement(ObjectId(ID_GEOM); content_id = ContentId("geom-bytes"))]
        profile = ArchiveProfile(;
            archive_id = "archive-fixed-id",
            package_version = "9.9.9",
            features = (:jld2_writer, :embedded_schemas, :namespaces),
        )
        write_archive(
            path;
            graph = graph,
            namespaces = namespaces,
            schemas = schemas,
            externals = externals,
            profile = profile,
        )

        @test is_hdf5_container(path)
        @test is_ah5_archive(path)
        inspection = inspect_archive(path)
        @test inspection.identified
        @test isvalid(validate(inspection))
        @test isready(readiness(inspection, PipelineTarget(:inspect)))
        @test inspection.profile.magic == AH5_MAGIC
        @test inspection.profile.profile_version == AH5_PROFILE_VERSION
        @test inspection.profile.archive_id == "archive-fixed-id"
        @test inspection.profile.package_version == "9.9.9"
        @test inspection.profile.profile_version != inspection.profile.package_version
        @test inspection.profile.roots.schemas == AH5_SCHEMAS_KEY
        @test Set(inspection.profile.features) == Set(AH5_V1_FEATURES)
        @test isempty(inspection.profile.required_features)
        @test inspection.history.objects == 2
        @test inspection.history.head_names === (:main,)
        @test inspection.provenance.software_environments === ("sw-delone",)
        @test any(ns -> ns.namespace.id === :delone, inspection.namespaces)
        @test any(ns -> ns.namespace.id === :oodi, inspection.namespaces)
        schema_ids = [listing.schema for listing in inspection.schemas]
        @test SchemaRef(:delone, "mesh", "1.0.0") in schema_ids
        @test SchemaRef(:oodi, "field", "1.0.0") in schema_ids
        mesh_listing = inspection.schemas[findfirst(l -> l.schema.schema_id == "mesh", inspection.schemas)]
        @test mesh_listing.fields[1].element.units == "m"
        @test mesh_listing.fields[1].rank == 2
        field_listing = inspection.schemas[findfirst(l -> l.schema.schema_id == "field", inspection.schemas)]
        @test getfield.(field_listing.node_schema.attributes, :name) == [:name, :scale]
        @test length(inspection.externals) == 1
        @test inspection.externals[1].object_id == ObjectId(ID_GEOM)
        @test !hasfield(typeof(inspection.profile), :julia_type)
        @test :julia_type ∉ keys(to_namedtuple(inspection.profile))

        renamed = joinpath(dir, "study.bin")
        cp(path, renamed)
        renamed_view = inspect_archive(renamed)
        @test renamed_view.identified
        @test renamed_view.profile.archive_id == "archive-fixed-id"
        @test is_ah5_archive(renamed)
    end
end

@testset "unrelated HDF5 and missing profile are rejected cleanly" begin
    mktempdir() do dir
        fake = joinpath(dir, "other.ah5")
        open(fake, "w") do io
            write(io, HDF5_SIGNATURE)
            write(io, zeros(UInt8, 64))
        end
        @test is_hdf5_container(fake)
        fake_view = inspect_archive(fake)
        @test !fake_view.identified
        @test any(d -> d.code === :not_ah5_archive, fake_view.diagnostics)
        @test !isvalid(validate(fake_view))

        text = joinpath(dir, "notes.ah5")
        write(text, "not hdf5")
        text_view = inspect_archive(text)
        @test !is_hdf5_container(text)
        @test !text_view.identified
        @test any(d -> d.code === :not_ah5_archive, text_view.diagnostics)

        jld2_only = joinpath(dir, "plain.ah5")
        JLD2.jldsave(jld2_only; foo = 1)
        missing_profile = inspect_archive(jld2_only)
        @test is_hdf5_container(jld2_only)
        @test !missing_profile.identified
        @test any(d -> d.code === :missing_profile, missing_profile.diagnostics)

        missing = inspect_archive(joinpath(dir, "absent.ah5"))
        @test any(d -> d.code === :missing_archive, missing.diagnostics)
    end
end

@testset "unsupported AH5 versions and required features fail before domain interpretation" begin
    mktempdir() do dir
        future = joinpath(dir, "future.ah5")
        write_archive(
            future;
            schemas = SchemaRegistry([_mesh_def()]),
            profile = ArchiveProfile(; archive_id = "future-id", profile_version = "2.0.0"),
        )
        stored_count = JLD2.jldopen(future, "r"; plain = true) do file
            file["episteme/schemas/count"]
        end
        @test stored_count == 1
        future_view = inspect_archive(future)
        @test future_view.identified
        @test any(d -> d.code === :unsupported_profile_version, future_view.diagnostics)
        @test isempty(future_view.schemas)
        @test isempty(future_view.namespaces)
        @test future_view.history.objects == 0
        @test !isready(readiness(future_view, PipelineTarget(:inspect)))

        bulk = joinpath(dir, "bulk.ah5")
        write_archive(
            bulk;
            schemas = SchemaRegistry([_mesh_def()]),
            profile = ArchiveProfile(;
                archive_id = "bulk-id",
                features = (:jld2_writer, :hdf5_bulk_data),
                required_features = (:hdf5_bulk_data,),
            ),
        )
        bulk_stored = JLD2.jldopen(bulk, "r"; plain = true) do file
            file["episteme/schemas/count"]
        end
        @test bulk_stored == 1
        bulk_view = inspect_archive(bulk)
        @test bulk_view.identified
        @test any(d -> d.code === :unsupported_required_feature, bulk_view.diagnostics)
        @test isempty(bulk_view.schemas)

        undeclared = joinpath(dir, "undeclared.ah5")
        @test_throws ArgumentError write_archive(
            undeclared;
            profile = ArchiveProfile(;
                archive_id = "undeclared-id",
                required_features = (:hdf5_bulk_data,),
            ),
        )
        @test !ispath(undeclared)

        crafted = joinpath(dir, "crafted.ah5")
        JLD2.jldopen(crafted, "w") do file
            file[AH5_PROFILE_KEY] = (
                magic = AH5_MAGIC,
                profile_version = AH5_PROFILE_VERSION,
                archive_id = "crafted-id",
                created_at = "2026-01-01T00:00:00Z",
                creator = "Episteme.jl",
                features = ["jld2_writer"],
                required_features = ["hdf5_bulk_data"],
                roots = (
                    namespaces = AH5_NAMESPACES_KEY,
                    schemas = AH5_SCHEMAS_KEY,
                    history = AH5_HISTORY_KEY,
                    provenance = AH5_PROVENANCE_KEY,
                    externals = AH5_EXTERNALS_KEY,
                ),
                package_version = "0.1.0",
            )
            file["episteme/schemas/count"] = 1
            file["episteme/schemas/1"] = (
                namespace_id = "delone",
                schema_id = "mesh",
                version = "1.0.0",
                package_uuid = "",
                display_name = "",
                compatibility = "exact_read",
                documentation = "",
                package_version = "",
                field_names = String[],
                field_kinds = String[],
                field_units = String[],
                field_frames = String[],
                field_enums = String[],
                field_ranks = Int[],
                field_shapes = String[],
                field_required = Bool[],
                field_cardinality = String[],
                field_support = String[],
                field_location = String[],
                field_refs = String[],
                field_docs = String[],
                field_rules = String[],
                has_node_schema = false,
                node_kind = "",
                node_allow_extra = false,
                attr_names = String[],
                attr_kinds = String[],
                attr_required = Bool[],
                attr_allow_ref = Bool[],
                attr_rules = String[],
                node_rule_kinds = String[],
                node_rule_params = String[],
                node_rule_messages = String[],
                replaces_ns = "",
                replaces_id = "",
                replaces_version = "",
                replaced_by_ns = "",
                replaced_by_id = "",
                replaced_by_version = "",
                migration_source_ns = "",
                migration_source_id = "",
                migration_source_version = "",
                migration_target_ns = "",
                migration_target_id = "",
                migration_target_version = "",
                migration_impl = "",
            )
        end
        crafted_view = inspect_archive(crafted)
        @test crafted_view.identified
        @test any(d -> d.code === :required_feature_missing, crafted_view.diagnostics)
        @test isempty(crafted_view.schemas)

        corrupt = joinpath(dir, "corrupt.ah5")
        JLD2.jldopen(corrupt, "w") do file
            file[AH5_PROFILE_KEY] = (; magic = 1, not_a_profile = true)
        end
        corrupt_view = inspect_archive(corrupt)
        @test any(d -> d.code === :corrupt_profile, corrupt_view.diagnostics)
    end
end

@testset "AH5 writer is JLD2 and does not treat /_types as schema identity" begin
    mktempdir() do dir
        path = joinpath(dir, "types.ah5")
        write_archive(path; schemas = SchemaRegistry([_mesh_def()]))
        inspection = inspect_archive(path)
        @test inspection.identified
        @test inspection.schemas[1].schema == SchemaRef(:delone, "mesh", "1.0.0")
        @test inspection.profile.package_version != inspection.schemas[1].schema.version
        names = JLD2.jldopen(path, "r"; plain = true) do file
            keys(file)
        end
        @test "episteme" in names || any(startswith("episteme"), string.(names))
        @test_throws ArgumentError write_archive(path)
    end
end

@testset "AH5 roots, feature flags, and write-time validation honor the profile contract" begin
    mktempdir() do dir
        custom = joinpath(dir, "custom.ah5")
        roots = ArchiveProfileRoots(; schemas = "episteme/schema_registry_v2")
        write_archive(
            custom;
            schemas = SchemaRegistry([_mesh_def()]),
            profile = ArchiveProfile(; archive_id = "custom-id", roots = roots),
        )
        custom_view = inspect_archive(custom)
        @test custom_view.identified
        @test custom_view.profile.roots.schemas == "episteme/schema_registry_v2"
        @test custom_view.schemas[1].schema == SchemaRef(:delone, "mesh", "1.0.0")
        JLD2.jldopen(custom, "r"; plain = true) do file
            @test haskey(file, "episteme/schema_registry_v2/count")
            @test file["episteme/schema_registry_v2/count"] == 1
            @test !haskey(file, "episteme/schemas/count")
            @test haskey(file, AH5_PROFILE_KEY)
        end

        default = joinpath(dir, "default.ah5")
        write_archive(default)
        default_view = inspect_archive(default)
        @test Set(default_view.profile.features) == Set(AH5_V1_FEATURES)
        @test isvalid(validate(default_view))

        missing_schema = joinpath(dir, "missing-schema.ah5")
        graph = ArchiveGraph([_obj(:delone, "mesh", ID_MESH, REV_1; uuid = UUID_DELONE)])
        @test_throws ArgumentError write_archive(
            missing_schema;
            graph = graph,
            schemas = SchemaRegistry(),
        )
        @test !ispath(missing_schema)
        @test_throws ArgumentError write_archive(missing_schema; graph = graph)
        @test !ispath(missing_schema)

        uuid_mismatch = joinpath(dir, "uuid-mismatch.ah5")
        @test_throws ArgumentError write_archive(
            uuid_mismatch;
            graph = ArchiveGraph([_obj(:delone, "mesh", ID_MESH, REV_1; uuid = UUID_OODI)]),
            schemas = SchemaRegistry([_mesh_def()]),
        )
        @test !ispath(uuid_mismatch)

        delimited = joinpath(dir, "delimited.ah5")
        choice = SchemaDefinition(
            SchemaRef(:oodi, "choice", "1.0.0");
            namespace = ArchiveNamespace(:oodi; package_uuid = UUID_OODI, display_name = "Oodi.jl"),
            fields = [
                SchemaField(
                    :label,
                    LogicalType(:enum; enum_values = (Symbol("a,b"), Symbol("c=d")));
                    rules = (
                        ValidationRule(
                            :one_of;
                            values = ("a,b", "c=d+e"),
                            message = "pick\tone\nof",
                        ),
                    ),
                    documentation = "enum,with=delimiters",
                ),
            ],
            node_schema = NodeSchema(
                Symbol("oodi/choice"),
                AttributeSchema(
                    :min,
                    :real;
                    rules = (ValidationRule(:finite; message = "must be finite"),),
                ),
                AttributeSchema(
                    :max,
                    :real;
                    rules = (ValidationRule(:gt; value = 0.0, message = "a,b=c"),),
                );
                rules = (
                    NodeValidationRule(:ordered; fields = (:min, :max), message = "min<=max\nplease"),
                ),
            ),
            documentation = "delimiter round-trip",
        )
        write_archive(delimited; schemas = SchemaRegistry([choice]))
        listed = inspect_archive(delimited).schemas[1]
        @test listed.fields[1].element.enum_values === (Symbol("a,b"), Symbol("c=d"))
        @test listed.fields[1].rules[1].parameters.values === ("a,b", "c=d+e")
        @test listed.fields[1].rules[1].message == "pick\tone\nof"
        @test listed.node_schema.attributes[2].rules[1].parameters.value == 0.0
        @test listed.node_schema.attributes[2].rules[1].message == "a,b=c"
        @test listed.node_schema.rules[1].parameters.fields === (:min, :max)
        @test listed.node_schema.rules[1].message == "min<=max\nplease"
    end
end

@testset "external metadata survives projection and portable AH5 storage" begin
    metadata = (
        z_label = "µ,=\t\n",
        unit = "m",
        dimensions = (2, 3, 0),
        labels = (:x, :y, "z"),
        description = (value = 1.25, enabled = true, absent = nothing),
        path = "descriptive path", uri = :descriptive_uri, kind = "descriptive kind",
        empty_tuple = (),
        empty_record = (;),
        nested = ((z = (1, false), a = "nested"),),
    )
    req = ExternalRequirement(ObjectId("external-metadata-input");
        content_id = ContentId("sha256:" * "a"^64),
        artifact = ArtifactRef(:file, "data.bin", "file:data.bin",
            "portable input", metadata))
    projected = to_namedtuple(req)
    @test projected.artifact == to_namedtuple(req.artifact)
    @test projected.artifact.metadata === metadata
    @test !haskey(projected.artifact.metadata, :metadata)
    @test to_namedtuple(from_namedtuple(ExternalRequirement, projected)) == projected

    mktempdir() do dir
        path = joinpath(dir, "metadata.ah5")
        write_archive(path; externals = [req])
        view = inspect_archive(path)
        @test view.identified
        @test isvalid(validate(view))
        restored = only(view.externals)
        @test restored.object_id == req.object_id
        @test restored.content_id == req.content_id
        @test to_namedtuple(restored.artifact) == to_namedtuple(req.artifact)
        @test keys(restored.artifact.metadata) == keys(metadata)
        @test keys(restored.artifact.metadata.nested[1]) == (:z, :a)
        @test restored.artifact.metadata.dimensions === (2, 3, 0)
        @test restored.artifact.metadata.labels === (:x, :y, "z")
        @test view.profile.profile_version == AH5_PROFILE_VERSION
        @test isempty(view.schemas)
        named = ExternalRequirement(ObjectId("named-metadata");
            artifact = ArtifactRef(:file; metadata = (unit = "m",)))
        named_path = joinpath(dir, "named-metadata.ah5")
        write_archive(named_path; externals = [named])
        @test only(inspect_archive(named_path).externals).artifact.metadata ==
            (metadata = (unit = "m",),)
        JLD2.jldopen(path, "r"; plain = true) do file
            raw = file["$(AH5_EXTERNALS_KEY)/1"]
            @test raw.artifact_metadata.portable_kind == "namedtuple"
            @test String.(getproperty.(raw.artifact_metadata.items, :name)) ==
                collect(String.(keys(metadata)))
            # The historical decoder reads its six fields without knowing the
            # optional metadata; identity/location remain consumable.
            old = ArtifactRef(Symbol(raw.artifact_kind);
                path = String(raw.artifact_path), uri = String(raw.artifact_uri),
                description = String(raw.artifact_description))
            @test old.path == req.artifact.path
            @test old.uri == req.artifact.uri
            @test isempty(old.metadata)
            @test String(raw.object_id) == req.object_id.value
            @test String(raw.content_id) == req.content_id.value
        end
    end
end

@testset "historical external rows restore empty metadata" begin
    historical = (
        object_id = "historical-input", content_id = "historical-bytes",
        artifact_kind = "file", artifact_path = "old.bin", artifact_uri = "",
        artifact_description = "historical description",
    )
    projection = (
        object_id = historical.object_id, content_id = historical.content_id,
        artifact = (kind = :file, path = "old.bin", uri = nothing,
                    description = historical.artifact_description),
    )
    @test isempty(from_namedtuple(ExternalRequirement, projection).artifact.metadata)
    mktempdir() do dir
        path = joinpath(dir, "historical.ah5")
        write_archive(path)
        JLD2.jldopen(path, "r+") do file
            delete!(file, "$(AH5_EXTERNALS_KEY)/count")
            file["$(AH5_EXTERNALS_KEY)/count"] = 1
            file["$(AH5_EXTERNALS_KEY)/1"] = historical
        end
        before = read(path)
        view = inspect_archive(path)
        @test view.identified
        @test isvalid(validate(view))
        req = only(view.externals)
        @test req.object_id == ObjectId("historical-input")
        @test req.content_id == ContentId("historical-bytes")
        @test req.artifact.path == "old.bin"
        @test req.artifact.uri === nothing
        @test isempty(req.artifact.metadata)
        @test read(path) == before
    end
end

@testset "unsupported external metadata refuses output before publication" begin
    safe = ExternalRequirement(ObjectId("safe"); artifact = ArtifactRef(:file; unit = "m"))
    unsafe = (x -> x, Ref(1), [1, 2], Dict(:x => 1), Float32(1), typemax(UInt), 'x')
    mktempdir() do dir
        for (i, value) in enumerate(unsafe)
            req = ExternalRequirement(ObjectId("unsafe");
                artifact = ArtifactRef(:file; nested = (label = "safe", value = (value,))))
            path = joinpath(dir, "unsupported-$i.ah5")
            @test_throws ArgumentError write_archive(path; externals = [safe, req])
            @test !ispath(path)
            @test readdir(dir) == String[]
            write(path, "existing bytes")
            @test_throws ArgumentError write_archive(path; externals = [safe, req])
            @test read(path, String) == "existing bytes"
            rm(path)
        end
    end
end

@testset "unsupported external metadata tags refuse archive inspection" begin
    mktempdir() do dir
        for (i, metadata) in enumerate((
            (portable_kind = "tuple", items = Any[]),
            (portable_kind = "namedtuple", items = Any[
                (name = "unit", value = (portable_kind = "string", value = "m")),
                (name = "unit", value = (portable_kind = "string", value = "mm")),
            ]),
            (portable_kind = "namedtuple", items = Any[(name = "bad",
                value = (portable_kind = "encoded", kind = "opaque",
                    data = (portable_kind = "namedtuple", items = Any[])))]),
        ))
            path = joinpath(dir, "corrupt-metadata-$i.ah5")
            write_archive(path)
            JLD2.jldopen(path, "r+") do file
                delete!(file, "$(AH5_EXTERNALS_KEY)/count")
                file["$(AH5_EXTERNALS_KEY)/count"] = 1
                file["$(AH5_EXTERNALS_KEY)/1"] = (
                    object_id = "corrupt-input", content_id = "",
                    artifact_kind = "file", artifact_path = "", artifact_uri = "",
                    artifact_description = "", artifact_metadata = metadata,
                )
            end
            view = inspect_archive(path)
            @test view.identified
            @test !isvalid(validate(view))
            @test isempty(view.externals)
        end
    end
end
