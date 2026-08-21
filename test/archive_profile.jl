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
    end
end
