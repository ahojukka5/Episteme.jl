# Reproduction capsule v1 (#35). Generic inspection must not require domain packages.

struct CapsuleToyNative
    n::Int
end

function Episteme.canonical_content(value::CapsuleToyNative)
    return (; n = value.n)
end

function _capsule_component(; version = "1.0.0", dirty = false)
    return SoftwareComponent(
        "app", "Application";
        version = version,
        source_identity = "git:" * repeat("b", 40),
        dirty = dirty,
        dependencies = (),
        features = (),
    )
end

function _capsule_environment(; version = "1.0.0", dirty = false, julia_version = "1.12.7")
    return SoftwareEnvironment(
        (_capsule_component(; version = version, dirty = dirty),);
        julia_version = julia_version,
        features = (),
    )
end

_capsule_context() = ExecutionContext(; numerics = (precision = "Float64", deterministic = false))

function _capsule_document()
    node = SemanticNode(Symbol("example/model"), :model; residual = 0.25, converged = true)
    return capture_portable(DocumentId("spec-1"), node; metadata = (; role = "specification"))
end

function _capsule_codes(report)
    return [diagnostic.code for diagnostic in report.diagnostics]
end

function payload_content(integrity, payload)
    for row in integrity.dependencies
        row.kind === :object || continue
        row.object_id == payload.object_id || continue
        row.revision_id == payload.revision_id || continue
        return row.content_id
    end
    return nothing
end

function _capsule_rows(manifest, kind; status = nothing, reason = nothing, object_id = nothing)
    return [
        entry for entry in manifest.content if
        entry.kind === kind &&
            (status === nothing || entry.status === status) &&
            (reason === nothing || entry.reason === reason) &&
            (object_id === nothing || entry.object_id == object_id)
    ]
end

function _reproduction_graph(;
    environment = _capsule_environment(),
    context = _capsule_context(),
    input_value = (; size = 2, values = (1.0, 2.0)),
    output_value = (; residual = 0.25, converged = true),
)
    input_id = canonical_content_id(input_value)
    output_id = canonical_content_id(output_value)
    r0 = RevisionId(REV_1)
    r1 = RevisionId(REV_2)
    r_other = RevisionId(REV_3)
    run_id = RunId("run-capsule-1")
    activity_id = ActivityId("activity-capsule-1")
    input = _obj(:delone, "mesh", ID_GEOM, REV_1; content = input_id.value, uuid = UUID_DELONE)
    output = _obj(:delone, "mesh", ID_MESH, REV_2;
        content = output_id.value, run = run_id.value, uuid = UUID_DELONE,
        references = [ArchiveReference(:input, ObjectId(ID_GEOM); revision_id = r0)])
    unrelated = _obj(:delone, "mesh", ID_FIELD, REV_3;
        content = "sha256:" * repeat("e", 64), uuid = UUID_DELONE)
    activity = ActivityRecord(activity_id, run_id, Symbol("delone/build");
        idempotency_key = "build-capsule-1",
        used = [ArchiveReference(:input, ObjectId(ID_GEOM); revision_id = r0)],
        generated = [ArchiveReference(:output, ObjectId(ID_MESH); revision_id = r1)],
        reuse = :computed)
    staged = StagedObject(ObjectId(ID_MESH);
        content_id = output_id,
        namespace = ArchiveNamespace(:delone; package_uuid = UUID_DELONE, display_name = "Delone.jl"),
        kind = Symbol("delone/mesh"),
        schema = SchemaRef(:delone, "mesh", "1.0.0"),
        origin = :generated,
        activity_id = activity_id,
        references = [ArchiveReference(:input, ObjectId(ID_GEOM); revision_id = r0)])
    restart = RestartRequirement(;
        checkpoints = [CheckpointRef(ObjectId(ID_MESH);
            content_id = output_id, revision_id = r1, kind = :checkpoint)],
        execution_context = context.id,
        from_activity_id = activity_id)
    run = RunRecord(run_id;
        plan_id = PlanId("plan-capsule-1"),
        revision_id = r1,
        status = :completed,
        software_environment = environment.id,
        execution_context = context.id,
        activities = [activity],
        staged = [staged],
        restart = restart)
    pinned = EventRecord(:committed, run_id; sequence = 1, retention = :pinned, message = "kept")
    debug_event = EventRecord(:note, run_id; sequence = 2, retention = :debug, message = "drop-me")
    logs = [
        LogStreamRecord(run_id, :stderr; retention = :debug, summary = "debug-log"),
        LogStreamRecord(run_id, :stdout; retention = :forensic, summary = "kept-log"),
    ]
    graph = ArchiveGraph([unrelated, input, output];
        revisions = [RevisionRecord(r0), RevisionRecord(r1; parents = [r0], run_id = run_id,
            plan_id = PlanId("plan-capsule-1")), RevisionRecord(r_other)],
        runs = [run],
        events = [pinned, debug_event],
        log_streams = logs)
    payloads = [
        CapsulePayload(input.object_id, input.revision_id, input_value),
        CapsulePayload(output.object_id, output.revision_id, output_value),
    ]
    return (;
        graph, environment, context, payloads, input, output, input_value, output_value,
        root = r1, parent = r0, run,
    )
end

function _reproduction_plan(parts; target = :rerun, externals = ExternalRequirement[], external_integrity = ExternalIntegrityRecord[], verification = :metadata)
    return plan_capsule(parts.graph, parts.root, SchemaRegistry([_mesh_def()]);
        target = target, externals = externals, external_integrity = external_integrity,
        verification = verification)
end

function _write_reproduction(path, parts, plan;
    payloads = parts.payloads, documents = _capsule_document(), redactions = CapsuleRedaction[],
    native_policy = false, software = true, environments = nothing, externals = ExternalRequirement[],
)
    registry = if environments !== nothing
        environments
    elseif software
        SoftwareEnvironmentRegistry((parts.environment,))
    else
        nothing
    end
    return write_capsule_archive(path, parts.graph, plan, SchemaRegistry([_mesh_def()]);
        source_archive_id = "source-archive",
        payloads = payloads,
        documents = documents,
        redactions = redactions,
        native_policy = native_policy,
        software_environments = registry,
        execution_contexts = ExecutionContextRegistry((parts.context,)),
        externals = externals)
end

@testset "reproduction capsule embeds the retained closure and all four readiness levels" begin
    parts = _reproduction_graph()
    plan = _reproduction_plan(parts)
    @test isvalid(plan)
    @test isvalid(validate(parts.graph))
    before = to_namedtuple(parts.graph)
    objects = parts.graph.objects
    extra_env = _capsule_environment(; version = "9.9.9")
    mktempdir() do dir
        source_path = joinpath(dir, "source.ah5")
        write_event_archive(source_path, parts.graph; schemas = SchemaRegistry([_mesh_def()]))
        source_bytes = read(source_path)
        path = joinpath(dir, "capsule.ah5")
        result = _write_reproduction(path, parts, plan;
            environments = SoftwareEnvironmentRegistry((extra_env, parts.environment)))
        @test result.source_unchanged
        @test result.manifest.format_version == 2
        @test result.manifest.source_archive_id == "source-archive"
        @test result.manifest.archive_id != "source-archive"
        @test only(result.manifest.root_revisions) == parts.root
        @test result.manifest.payloads_embedded
        @test result.manifest.readiness.inspectable
        @test result.manifest.readiness.replayable
        @test result.manifest.readiness.restartable
        @test result.manifest.readiness.rerunnable
        @test parts.graph.objects === objects
        @test to_namedtuple(parts.graph) == before
        @test read(source_path) == source_bytes
        @test sort(readdir(dir)) == ["capsule.ah5", "source.ah5"]

        view = inspect_archive(path, CapsuleManifest)
        @test isvalid(view)
        @test to_namedtuple(view.manifest) == to_namedtuple(result.manifest)
        @test view.achieved.inspectable && view.achieved.replayable
        @test view.achieved.restartable && view.achieved.rerunnable
        for target in (:inspect, :replay, :restart, :rerun)
            @test isready(readiness(view, PipelineTarget(target)))
        end
        @test sort([payload.object_id.value for payload in view.payloads]) == [ID_GEOM, ID_MESH]
        # Portable named tuples restore in canonical field order. Identity, not
        # Julia field order, is the replay contract.
        for (object_id, expected) in ((ID_GEOM, parts.input_value), (ID_MESH, parts.output_value))
            restored = only(payload.value for payload in view.payloads if payload.object_id.value == object_id)
            @test canonical_content_id(restored) == canonical_content_id(expected)
            @test sort(collect(pairs(restored)); by = pair -> String(first(pair))) ==
                sort(collect(pairs(expected)); by = pair -> String(first(pair)))
        end
        @test only(view.documents).id == DocumentId("spec-1")
        @test isvalid(validate(only(view.documents)))

        core = inspect_archive(path)
        mesh_schema = only(schema for schema in core.schemas if schema.schema.schema_id == "mesh")
        @test mesh_schema.package_version == "0.4.0"
        history = inspect_archive(path, ArchiveEventHistory)
        restored = reconstruct_graph(history)
        @test Set(revision.id for revision in restored.revisions) == Set([parts.parent, parts.root])
        @test Set(object.object_id for object in restored.objects) == Set([ObjectId(ID_GEOM), ObjectId(ID_MESH)])
        @test only(restored.events).retention === :pinned
        @test only(restored.log_streams).retention === :forensic
        software = inspect_archive(path, SoftwareEnvironmentRegistry)
        @test find_software_environment(software.registry, parts.environment.id) !== nothing
        @test find_software_environment(software.registry, extra_env.id) === nothing
        @test length(_capsule_rows(view.manifest, :runtime; status = :omitted, reason = :runtime_not_packaged)) == 1
        @test only(_capsule_rows(view.manifest, :runtime)).label == "os-runtime-container"
        @test !isempty(_capsule_rows(view.manifest, :object; status = :omitted, reason = :unreachable, object_id = ID_FIELD))
        @test !isempty(_capsule_rows(view.manifest, :debug; status = :omitted, reason = :unpinned_debug))
        @test !isempty(_capsule_rows(view.manifest, :log; status = :unavailable, reason = :log_bytes_not_packaged))
        @test !isempty(_capsule_rows(view.manifest, :schema; status = :included))
        @test !isempty(_capsule_rows(view.manifest, :provenance; status = :included))
        @test !isempty(_capsule_rows(view.manifest, :software_environment; status = :included))
        @test !isempty(_capsule_rows(view.manifest, :execution_context; status = :included))
        @test !isempty(_capsule_rows(view.manifest, :document; status = :included))
        @test !isempty(_capsule_rows(view.manifest, :revision; status = :included, reason = :retention_root))
        @test !isempty(_capsule_rows(view.manifest, :revision; status = :included, reason = :ancestor))
        @test !isempty(_capsule_rows(view.manifest, :revision; status = :omitted, reason = :unreachable))
        integrity = only(inspect_archive(path, RevisionIntegrityManifest).manifests)
        for payload in view.payloads
            @test canonical_content_id(payload.value) == payload_content(integrity, payload)
        end
        checked = verify_capsule(path)
        @test isvalid(checked)
        @test isready(readiness(checked, PipelineTarget(:rerun)))
    end
end

@testset "missing capsule evidence downgrades execution readiness" begin
    mktempdir() do dir
        parts = _reproduction_graph()
        plan = _reproduction_plan(parts)
        no_doc = joinpath(dir, "no-doc.ah5")
        _write_reproduction(no_doc, parts, plan; documents = nothing)
        view = inspect_archive(no_doc, CapsuleManifest)
        @test view.achieved.inspectable && view.achieved.replayable && view.achieved.restartable
        @test !view.achieved.rerunnable
        @test :portable_specification_missing in _capsule_codes(readiness(view, PipelineTarget(:rerun)))

        incomplete = _reproduction_graph(; environment = _capsule_environment(; version = nothing))
        incomplete_plan = _reproduction_plan(incomplete)
        @test isvalid(incomplete_plan)
        incomplete_path = joinpath(dir, "incomplete.ah5")
        _write_reproduction(incomplete_path, incomplete, incomplete_plan)
        incomplete_view = inspect_archive(incomplete_path, CapsuleManifest)
        @test incomplete_view.achieved.replayable && !incomplete_view.achieved.rerunnable
        @test :rerun_dependencies_absent in _capsule_codes(readiness(incomplete_view, PipelineTarget(:rerun)))

        dirty = _reproduction_graph(; environment = _capsule_environment(; dirty = true))
        dirty_plan = _reproduction_plan(dirty)
        dirty_path = joinpath(dir, "dirty.ah5")
        _write_reproduction(dirty_path, dirty, dirty_plan)
        dirty_view = inspect_archive(dirty_path, CapsuleManifest)
        @test dirty_view.achieved.replayable && !dirty_view.achieved.rerunnable
        @test :modified_software_source in _capsule_codes(readiness(dirty_view, PipelineTarget(:rerun)))

        missing_env = joinpath(dir, "missing-env.ah5")
        _write_reproduction(missing_env, parts, plan; software = false)
        missing_view = inspect_archive(missing_env, CapsuleManifest)
        @test missing_view.achieved.inspectable && missing_view.achieved.restartable
        @test !missing_view.achieved.replayable && !missing_view.achieved.rerunnable
        @test :software_environment_record_missing in _capsule_codes(readiness(missing_view, PipelineTarget(:replay)))

        redacted = joinpath(dir, "redacted.ah5")
        marker = (; marker = "capsule-redaction-marker", residual = 1.0, converged = false)
        _write_reproduction(redacted, parts, plan;
            payloads = [
                parts.payloads[1],
                CapsulePayload(parts.output.object_id, parts.output.revision_id, marker),
            ],
            redactions = [CapsuleRedaction(parts.output.object_id, parts.output.revision_id)])
        redacted_view = inspect_archive(redacted, CapsuleManifest)
        @test redacted_view.achieved.inspectable
        @test !redacted_view.achieved.replayable && !redacted_view.achieved.restartable
        @test only(_capsule_rows(redacted_view.manifest, :payload; object_id = ID_MESH)).status === :redacted
        @test only(_capsule_rows(redacted_view.manifest, :payload; object_id = ID_MESH)).reason === :caller_redacted
        @test !occursin("capsule-redaction-marker", String(read(redacted)))

        omitted = joinpath(dir, "omitted.ah5")
        _write_reproduction(omitted, parts, plan; payloads = [parts.payloads[1]])
        omitted_view = inspect_archive(omitted, CapsuleManifest)
        @test !omitted_view.achieved.replayable
        @test only(_capsule_rows(omitted_view.manifest, :payload; object_id = ID_MESH)).status === :unavailable
        @test only(_capsule_rows(omitted_view.manifest, :payload; object_id = ID_MESH)).reason === :payload_not_supplied

        secret = joinpath(dir, "secret.ah5")
        secret_value = (; api_key = "capsule-secret-marker", size = 2, values = (1.0, 2.0))
        _write_reproduction(secret, parts, plan;
            payloads = [
                CapsulePayload(parts.input.object_id, parts.input.revision_id, secret_value),
                parts.payloads[2],
            ])
        secret_view = inspect_archive(secret, CapsuleManifest)
        @test !secret_view.achieved.replayable
        @test only(_capsule_rows(secret_view.manifest, :payload; object_id = ID_GEOM)).status === :redacted
        @test only(_capsule_rows(secret_view.manifest, :payload; object_id = ID_GEOM)).reason === :credential_like_content
        @test !occursin("capsule-secret-marker", String(read(secret)))
        @test all(payload -> payload.object_id != ObjectId(ID_GEOM), secret_view.payloads)

        mismatch = joinpath(dir, "mismatch.ah5")
        before_mismatch = to_namedtuple(parts.graph)
        @test_throws ArgumentError _write_reproduction(mismatch, parts, plan;
            payloads = [
                parts.payloads[1],
                CapsulePayload(parts.output.object_id, parts.output.revision_id,
                    (; residual = 9.0, converged = false)),
            ])
        @test !ispath(mismatch)
        @test to_namedtuple(parts.graph) == before_mismatch
    end
end

@testset "external references keep restart without claiming replay or rerun" begin
    mktempdir() do dir
        external_path = joinpath(dir, "geometry.bin")
        write(external_path, repeat(UInt8[0x01, 0x03, 0x05, 0x07], 64))
        initial = ExternalRequirement(ObjectId(ID_SPACE);
            artifact = ArtifactRef(:file; path = external_path, description = "external geometry"))
        record = capture_external_integrity(initial)
        requirement = ExternalRequirement(ObjectId(ID_SPACE);
            content_id = record.content_id, artifact = initial.artifact)
        environment = _capsule_environment()
        context = _capsule_context()
        output_value = (; residual = 0.25, converged = true)
        output_id = canonical_content_id(output_value)
        r1 = RevisionId(REV_2)
        run_id = RunId("run-external-1")
        activity_id = ActivityId("activity-external-1")
        output = _obj(:delone, "mesh", ID_MESH, REV_2;
            content = output_id.value, run = run_id.value, uuid = UUID_DELONE,
            references = [ArchiveReference(:geometry, ObjectId(ID_SPACE); revision_id = r1)])
        activity = ActivityRecord(activity_id, run_id, Symbol("delone/build");
            used = [ArchiveReference(:geometry, ObjectId(ID_SPACE); revision_id = r1)],
            generated = [ArchiveReference(:output, ObjectId(ID_MESH); revision_id = r1)],
            reuse = :computed)
        staged = StagedObject(ObjectId(ID_MESH);
            content_id = output_id,
            namespace = ArchiveNamespace(:delone; package_uuid = UUID_DELONE, display_name = "Delone.jl"),
            kind = Symbol("delone/mesh"),
            schema = SchemaRef(:delone, "mesh", "1.0.0"),
            origin = :generated,
            activity_id = activity_id)
        restart = RestartRequirement(;
            checkpoints = [CheckpointRef(ObjectId(ID_MESH);
                content_id = output_id, revision_id = r1, kind = :checkpoint)],
            execution_context = context.id,
            from_activity_id = activity_id)
        run = RunRecord(run_id;
            revision_id = r1, status = :completed,
            software_environment = environment.id, execution_context = context.id,
            activities = [activity], staged = [staged], restart = restart)
        graph = ArchiveGraph([output]; revisions = [RevisionRecord(r1; run_id = run_id)], runs = [run])
        parts = (; graph, environment, context, root = r1, payloads = CapsulePayload[
            CapsulePayload(output.object_id, output.revision_id, output_value),
        ])
        plan = plan_capsule(graph, r1, SchemaRegistry([_mesh_def()]);
            target = :restart, externals = [requirement], external_integrity = [record])
        @test isvalid(plan)
        path = joinpath(dir, "external.ah5")
        _write_reproduction(path, parts, plan; externals = [requirement])
        view = inspect_archive(path, CapsuleManifest)
        @test isvalid(view)
        @test view.achieved.inspectable && view.achieved.restartable
        @test !view.achieved.replayable && !view.achieved.rerunnable
        @test :external_content_required in _capsule_codes(readiness(view, PipelineTarget(:replay)))
        external_row = only(_capsule_rows(view.manifest, :external; status = :external))
        @test external_row.object_id == ID_SPACE
        @test external_row.reason === :external_reference
    end
end

function _container_def()
    return SchemaDefinition(
        SchemaRef(:packaging, "container_image", "1.0.0");
        namespace = ArchiveNamespace(:packaging; package_uuid = UUID_DELONE, display_name = "Packaging"),
        compatibility = :exact_read,
        fields = _mesh_fields(),
        documentation = "refused runtime image",
        package_version = "0.0.0",
    )
end

@testset "runtime images are omitted and native replay waits for verification" begin
    mktempdir() do dir
        value = (; n = 1)
        image = _obj(:packaging, "container_image", ID_VOL, REV_1;
            content = canonical_content_id(value).value, uuid = UUID_DELONE)
        graph = ArchiveGraph([image]; revisions = [RevisionRecord(RevisionId(REV_1))])
        schemas = SchemaRegistry([_container_def()])
        plan = plan_capsule(graph, RevisionId(REV_1), schemas)
        @test isvalid(plan)
        path = joinpath(dir, "runtime.ah5")
        write_capsule_archive(path, graph, plan, schemas;
            source_archive_id = "source-archive",
            payloads = [CapsulePayload(image.object_id, image.revision_id, value)])
        view = inspect_archive(path, CapsuleManifest)
        @test isvalid(view)
        @test !view.manifest.payloads_embedded
        @test isempty(view.payloads)
        row = only(_capsule_rows(view.manifest, :payload; object_id = ID_VOL))
        @test row.status === :omitted
        @test row.reason === :runtime_not_packaged
        @test !view.achieved.replayable

        native = CapsuleToyNative(4)
        native_id = canonical_content_id(native)
        environment = _capsule_environment()
        context = _capsule_context()
        revision = RevisionId(REV_1)
        run_id = RunId("run-native-1")
        object = _obj(:delone, "mesh", ID_MESH, REV_1;
            content = native_id.value, run = run_id.value, uuid = UUID_DELONE)
        run = RunRecord(run_id;
            revision_id = revision, status = :completed,
            software_environment = environment.id, execution_context = context.id,
            activities = [ActivityRecord(ActivityId("activity-native-1"), run_id, Symbol("delone/build");
                generated = [ArchiveReference(:output, ObjectId(ID_MESH); revision_id = revision)])])
        native_graph = ArchiveGraph([object];
            revisions = [RevisionRecord(revision; run_id = run_id)], runs = [run])
        native_schemas = SchemaRegistry([_mesh_def()])
        native_plan = plan_capsule(native_graph, revision, native_schemas; target = :replay)
        @test isvalid(native_plan)
        native_path = joinpath(dir, "native.ah5")
        write_capsule_archive(native_path, native_graph, native_plan, native_schemas;
            source_archive_id = "source-archive",
            payloads = [CapsulePayload(object.object_id, object.revision_id, native)],
            documents = _capsule_document(),
            native_policy = true,
            software_environments = SoftwareEnvironmentRegistry((environment,)),
            execution_contexts = ExecutionContextRegistry((context,)))
        generic = inspect_archive(native_path, CapsuleManifest)
        @test isvalid(generic)
        @test isempty(generic.payloads)
        native_row = only(_capsule_rows(generic.manifest, :payload; object_id = ID_MESH))
        @test native_row.status === :included
        @test native_row.encoding == "native"
        @test generic.achieved.inspectable && !generic.achieved.replayable
        @test :native_replay_requires_verification in _capsule_codes(readiness(generic, PipelineTarget(:replay)))
        verified = verify_capsule(native_path; native_policy = true)
        @test isvalid(verified)
        @test verified.readiness.replayable
        @test only(verified.payloads).value == native
        refused = verify_capsule(native_path)
        @test isvalid(refused)
        @test !refused.readiness.replayable
        @test isempty(refused.payloads)

        flipped = joinpath(dir, "flipped.ah5")
        cp(native_path, flipped)
        key = Episteme._entry_key(Episteme.AH5_CAPSULE_NATIVE_KEY, 1)
        JLD2.jldopen(flipped, "r+") do file
            record = file[key]
            bytes = Vector{UInt8}(record.bytes)
            bytes[1] = bytes[1] == 0x00 ? 0x01 : 0x00
            delete!(file, key)
            file[key] = merge(record, (; bytes = bytes))
        end
        flipped_view = inspect_archive(flipped, CapsuleManifest)
        @test !isvalid(flipped_view)
        @test isempty(flipped_view.payloads)
        @test any(diagnostic -> occursin("byte hash mismatch", string(diagnostic.context)), flipped_view.diagnostics)
        @test !isvalid(verify_capsule(flipped; native_policy = true))

        portable_parts = _reproduction_graph()
        portable_plan = _reproduction_plan(portable_parts)
        portable_path = joinpath(dir, "portable.ah5")
        _write_reproduction(portable_path, portable_parts, portable_plan)
        payload_key = Episteme._entry_key(Episteme.AH5_CAPSULE_PAYLOADS_KEY, 1)
        JLD2.jldopen(portable_path, "r+") do file
            record = file[payload_key]
            delete!(file, payload_key)
            file[payload_key] = merge(record, (value = (
                portable_kind = "integer",
                value = 99,
            ),))
        end
        corrupted = inspect_archive(portable_path, CapsuleManifest)
        @test !isvalid(corrupted)
        @test corrupted.manifest === nothing
        @test isempty(corrupted.payloads)
    end
end
