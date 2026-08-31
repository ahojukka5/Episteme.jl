const CAPSULE_ARCHIVE_SOURCE_ID = "source-archive-capsule-fixture"
const CAPSULE_ARCHIVE_ID = "capsule-archive-fixture"
const CAPSULE_UNRELATED_CONTENT = "sha256:" * repeat("7", 64)

function _capsule_archive_fixture(dir)
    base, _, selected_revision = _event_history_fixture()
    selected_index = findfirst(
        object -> object.object_id == ObjectId(ID_MESH) &&
            object.revision_id == selected_revision,
        base.objects,
    )
    selected_index === nothing && error("event fixture has no selected mesh object")
    selected = base.objects[selected_index]

    external_path = joinpath(dir, "external-geometry.bin")
    write(external_path, repeat(UInt8[0x11, 0x22, 0x33, 0x44], 1024))
    external_id = ObjectId("capsule-external-geometry")
    initial_requirement = ExternalRequirement(
        external_id;
        artifact = ArtifactRef(
            :file;
            path = external_path,
            description = "external capsule geometry",
        ),
    )
    external_integrity = capture_external_integrity(
        initial_requirement;
        sample_bytes = 64,
        sample_count = 2,
    )
    requirement = ExternalRequirement(
        external_id;
        content_id = external_integrity.content_id,
        artifact = initial_requirement.artifact,
    )

    selected_with_external = ArchiveObject(
        selected.object_id,
        selected.revision_id;
        content_id = selected.content_id,
        run_id = selected.run_id,
        namespace = selected.namespace,
        kind = selected.kind,
        schema = selected.schema,
        provenance = selected.provenance,
        references = [
            selected.references...,
            ArchiveReference(:external_geometry, external_id),
        ],
    )

    objects = ArchiveObject[base.objects...]
    objects[selected_index] = selected_with_external

    unrelated_revision = RevisionId("capsule-unrelated-r1")
    unrelated = ArchiveObject(
        ObjectId("capsule-unrelated-field"),
        unrelated_revision;
        content_id = ContentId(CAPSULE_UNRELATED_CONTENT),
        namespace = ArchiveNamespace(
            :oodi;
            package_uuid = UUID_OODI,
            display_name = "Oodi.jl",
        ),
        kind = Symbol("oodi/field"),
        schema = SchemaRef(:oodi, "field", "1.0.0"),
    )

    graph = ArchiveGraph(
        [objects..., unrelated];
        heads = [
            base.heads...,
            WorkflowHead(
                WorkflowHeadId("capsule-unrelated-head"),
                :unrelated,
                unrelated_revision,
            ),
        ],
        revisions = [base.revisions..., RevisionRecord(unrelated_revision)],
        runs = base.runs,
        events = base.events,
        writes = base.writes,
        log_streams = base.log_streams,
    )
    schemas = SchemaRegistry([_mesh_def(), _field_def()])
    return graph, selected_revision, schemas, requirement, external_integrity, unrelated_revision
end

@testset "standalone AH5 capsule materializes only the retained inspectable closure" begin
    mktempdir() do dir
        graph, revision_id, schemas, requirement, external_integrity, unrelated_revision =
            _capsule_archive_fixture(dir)
        before = Episteme._capsule_source_snapshot(graph, [requirement])

        plan = plan_capsule(
            graph,
            revision_id,
            schemas;
            target = :inspect,
            externals = [requirement],
            external_integrity = [external_integrity],
            verification = :metadata,
        )
        @test isvalid(plan)
        @test isready(plan)
        @test plan.source_signature !== nothing
        @test startswith(plan.source_signature.value, "sha256:")
        @test plan.retention.omitted_objects >= 1
        @test unrelated_revision in plan.retention.omitted_revisions

        path = joinpath(dir, "capsule.ah5")
        result = write_capsule_archive(
            path,
            graph,
            plan,
            schemas;
            source_archive_id = CAPSULE_ARCHIVE_SOURCE_ID,
            externals = [requirement],
            capsule_archive_id = CAPSULE_ARCHIVE_ID,
        )
        @test result.source_unchanged
        @test isvalid(validate(result))
        @test result.manifest.capsule_archive_id == CAPSULE_ARCHIVE_ID
        @test result.manifest.source_archive_id == CAPSULE_ARCHIVE_SOURCE_ID
        @test !result.manifest.payloads_embedded
        @test Episteme._capsule_source_snapshot(graph, [requirement]) == before

        core = inspect_archive(path)
        @test core.identified
        @test core.profile.archive_id == CAPSULE_ARCHIVE_ID
        @test AH5_CAPSULE_FEATURE in core.profile.features
        @test AH5_INTEGRITY_FEATURE in core.profile.features
        @test length(core.schemas) == 1
        @test only(core.schemas).schema == SchemaRef(:delone, "mesh", "1.0.0")
        @test all(listing -> listing.namespace.id != :oodi, core.namespaces)
        @test length(core.externals) == 1
        @test only(core.externals).object_id == requirement.object_id
        @test only(core.externals).content_id == requirement.content_id

        capsule = inspect_archive(path, CapsuleArchiveManifest)
        @test isvalid(capsule)
        @test capsule.manifest !== nothing
        @test capsule.manifest.source_archive_id == CAPSULE_ARCHIVE_SOURCE_ID
        @test capsule.manifest.root_revisions == [revision_id]
        @test !capsule.manifest.payloads_embedded

        @test isready(readiness(capsule, PipelineTarget(:inspect)))
        for target in (:replay, :restart, :rerun)
            ready = readiness(capsule, PipelineTarget(target))
            @test !isready(ready)
            @test any(d -> d.code === :capsule_payloads_not_embedded, ready.diagnostics)
        end

        history = inspect_archive(path, ArchiveEventHistory)
        @test isvalid(history)
        reconstructed = reconstruct_graph(history)
        @test find_revision(reconstructed, revision_id) !== nothing
        @test find_revision(reconstructed, unrelated_revision) === nothing
        @test !any(object -> object.object_id == ObjectId("capsule-unrelated-field"), reconstructed.objects)
        @test length(reconstructed.events) == length(result.graph.events)
        @test event_timeline(reconstructed) == event_timeline(result.graph)
        @test length(reconstructed.writes) == length(result.graph.writes)
        @test length(reconstructed.log_streams) == length(result.graph.log_streams)

        manifest = inspect(reconstructed, revision_id; externals = core.externals)
        @test any(
            entry -> entry.object_id == requirement.object_id &&
                entry.availability === :external_required,
            manifest.entries,
        )

        integrity = inspect_archive(path, RevisionIntegrityManifest)
        @test isvalid(integrity)
        @test length(integrity.manifests) == 1
        @test only(integrity.manifests).revision_id == revision_id
    end
end

@testset "capsule materialization binds the frozen retained-source signature" begin
    mktempdir() do dir
        graph, revision_id, schemas, requirement, external_integrity, _ =
            _capsule_archive_fixture(dir)
        plan = plan_capsule(
            graph,
            revision_id,
            schemas;
            externals = [requirement],
            external_integrity = [external_integrity],
            verification = :metadata,
        )
        @test isvalid(plan)

        event = graph.events[1]
        graph.events[1] = EventRecord(
            event.kind,
            event.run_id;
            activity_id = event.activity_id,
            sequence = event.sequence,
            source = event.source,
            severity = event.severity,
            message = "changed after capsule planning",
            timestamp = event.timestamp,
            scope = event.scope,
            revision_id = event.revision_id,
            object_refs = event.object_refs,
            producer_id = event.producer_id,
            execution_context = event.execution_context,
            retention = event.retention,
            payload = event.payload,
        )

        path = joinpath(dir, "mutated-source.ah5")
        @test_throws ArgumentError write_capsule_archive(
            path,
            graph,
            plan,
            schemas;
            source_archive_id = CAPSULE_ARCHIVE_SOURCE_ID,
            externals = [requirement],
            capsule_archive_id = CAPSULE_ARCHIVE_ID,
        )
        @test !ispath(path)
    end
end

@testset "capsule inspector re-binds integrity to reconstructed metadata" begin
    mktempdir() do dir
        graph, revision_id, schemas, requirement, external_integrity, _ =
            _capsule_archive_fixture(dir)
        plan = plan_capsule(
            graph,
            revision_id,
            schemas;
            externals = [requirement],
            external_integrity = [external_integrity],
            verification = :metadata,
        )
        path = joinpath(dir, "forged-capsule.ah5")
        write_capsule_archive(
            path,
            graph,
            plan,
            schemas;
            source_archive_id = CAPSULE_ARCHIVE_SOURCE_ID,
            externals = [requirement],
            capsule_archive_id = CAPSULE_ARCHIVE_ID,
        )

        JLD2.jldopen(path, "r+") do file
            count = Int(file["$(AH5_STATE_HISTORY_KEY)/objects/count"])
            changed = false
            for index in 1:count
                key = "$(AH5_STATE_HISTORY_KEY)/objects/$index"
                raw = file[key]
                if String(raw.object_id) == ID_MESH
                    file[key] = merge(raw, (; content_id = "sha256:" * repeat("6", 64)))
                    changed = true
                    break
                end
            end
            @test changed
        end

        capsule = inspect_archive(path, CapsuleArchiveManifest)
        @test !isvalid(capsule)
        @test capsule.manifest === nothing
        @test any(d -> d.code === :capsule_integrity_binding_mismatch, capsule.diagnostics)
    end
end

@testset "capsule archive identity is distinct from source archive identity" begin
    mktempdir() do dir
        graph, revision_id, schemas, requirement, external_integrity, _ =
            _capsule_archive_fixture(dir)
        plan = plan_capsule(
            graph,
            revision_id,
            schemas;
            externals = [requirement],
            external_integrity = [external_integrity],
            verification = :metadata,
        )
        path = joinpath(dir, "same-id.ah5")
        @test_throws ArgumentError write_capsule_archive(
            path,
            graph,
            plan,
            schemas;
            source_archive_id = CAPSULE_ARCHIVE_SOURCE_ID,
            externals = [requirement],
            capsule_archive_id = CAPSULE_ARCHIVE_SOURCE_ID,
        )
        @test !ispath(path)
    end
end
