# Cross-workload archive qualification (#29).
#
# These fixtures are generic envelopes. They are not scientific domain schemas
# and they are not part of Episteme's model. Payloads stay in the working
# store or in external files. The archive APIs under test are the shipped
# ones; this file does not write its own container format.

import Episteme: apply_operation

const WQ_UUID = "12121212-1212-4121-8121-121212121212"
const WQ_NS = ArchiveNamespace(:workload; package_uuid = WQ_UUID, display_name = "Workload fixture")
const WQ_ENV = SoftwareEnvironmentId("workload-env")
const WQ_CTX = ExecutionContextId("workload-ctx")
const WQ_AGENT = AgentId("workload-agent")
const WQ_EXTERNAL_MARKER = "WQ-EXTERNAL-NOT-EMBEDDED"
const WQ_MEMORY_MARKER = "WQ-MEMORY-NOT-ARCHIVED"

struct WQNotPortable
    value::Int
end

wq_schema(id) = SchemaRef(:workload, id, "1")

const WQ_GEOMETRY = wq_schema("geometry-like")
const WQ_DISCRETIZATION = wq_schema("discretization-like")
const WQ_STATE = wq_schema("numerical-state")
const WQ_FIELD = wq_schema("field")
const WQ_CHECKPOINT = wq_schema("checkpoint")
const WQ_DEBUG = wq_schema("debug-product")
const WQ_EVIDENCE = wq_schema("evidence")
const WQ_INFERENCE = wq_schema("inference")
const WQ_PROBLEM = wq_schema("problem-metadata")
const WQ_SHARD = wq_schema("rank-local-vector")
const WQ_WEIGHTS = wq_schema("external-weights")
const WQ_MEASUREMENT = wq_schema("measurement")
const WQ_CANDIDATE = wq_schema("search-candidate")
const WQ_COST = wq_schema("cost-model")

function wq_array_field(name::Symbol, rank::Int; shape = ntuple(_ -> nothing, rank))
    return SchemaField(
        LogicalArraySpec(name, LogicalType(:real), rank; shape = shape);
        documentation = "logical array; chunking is not part of identity",
    )
end

function wq_definition(schema::SchemaRef, fields)
    return SchemaDefinition(
        schema;
        namespace = WQ_NS,
        fields = fields,
        documentation = "qualification fixture, not a domain schema",
    )
end

function wq_registry(pairs...)
    return SchemaRegistry([wq_definition(schema, fields) for (schema, fields) in pairs])
end

function wq_object(id, revision, schema; content, run = nothing, references = ArchiveReference[])
    return ArchiveObject(
        id isa ObjectId ? id : ObjectId(id),
        revision isa RevisionId ? revision : RevisionId(revision);
        content_id = content isa ContentId ? content : ContentId(content),
        run_id = run,
        namespace = WQ_NS,
        kind = schema_kind(schema),
        schema = schema,
        provenance = ProvenanceRefs(;
            software_environment = WQ_ENV,
            execution_context = WQ_CTX,
        ),
        references = references,
    )
end

function wq_commit!(graph, store, plan, revision)
    run = execute!(
        graph, plan;
        head = :main,
        store = store,
        software_environment = WQ_ENV,
        execution_context = WQ_CTX,
        agent_id = WQ_AGENT,
    )
    @test run.status === :completed
    @test run.revision_id === nothing
    @test find_head(graph, :main).revision_id != RevisionId(revision)
    commit!(graph, run.id; head = :main, store = store, revision_id = RevisionId(revision))
    committed = find_run(graph, run.id)
    @test committed.status === :completed
    @test committed.revision_id == RevisionId(revision)
    @test find_head(graph, :main).revision_id == RevisionId(revision)
    return committed
end

function wq_output(plan, spec, role, payload, schema; references = ArchiveReference[])
    return staged_result(
        plan_output_id(plan, spec, role),
        payload;
        namespace = WQ_NS,
        kind = schema_kind(schema),
        schema = schema,
        content_id = canonical_content_id(payload),
        references = references,
        provenance = ProvenanceRefs(;
            software_environment = WQ_ENV,
            execution_context = WQ_CTX,
        ),
    )
end

function wq_pinned(name, bound)
    object = bound.object
    return ArchiveReference(name, object.object_id; revision_id = object.revision_id)
end

function apply_operation(::Val{Symbol("workload/discretize")}, spec::OperationSpec, inputs; plan, kwargs...)
    geometry = inputs[:geometry]
    payload = (;
        class = "discretization-like",
        parent = geometry.payload.class,
        cells = 2,
    )
    return OperationOutcome(;
        outputs = [wq_output(plan, spec, :discretization, payload, WQ_DISCRETIZATION;
            references = [wq_pinned(:geometry, geometry)])],
    )
end

function apply_operation(::Val{Symbol("workload/advance")}, spec::OperationSpec, inputs; plan, kwargs...)
    discretization = inputs[:discretization]
    parent = wq_pinned(:discretization, discretization)
    state = (; class = "numerical-state", step = 1, marker = WQ_MEMORY_MARKER)
    field = (; class = "field", values = Float64[1.0, 0.5, 0.25, 0.125])
    return OperationOutcome(;
        outputs = [
            wq_output(plan, spec, :state, state, WQ_STATE; references = [parent]),
            wq_output(plan, spec, :field, field, WQ_FIELD; references = [parent]),
        ],
    )
end

function apply_operation(::Val{Symbol("workload/checkpoint")}, spec::OperationSpec, inputs; plan, kwargs...)
    state = inputs[:state]
    field = inputs[:field]
    payload = (; class = "checkpoint", step = state.payload.step, field = field.payload.class)
    staged = wq_output(plan, spec, :checkpoint, payload, WQ_CHECKPOINT;
        references = [wq_pinned(:state, state), wq_pinned(:field, field)])
    return OperationOutcome(;
        outputs = [staged],
        restart = RestartRequirement(;
            checkpoints = [CheckpointRef(
                staged.staged.object_id;
                content_id = staged.staged.content_id,
                kind = :checkpoint,
            )],
            execution_context = WQ_CTX,
        ),
    )
end

function apply_operation(::Val{Symbol("workload/debug")}, spec::OperationSpec, inputs; plan, kwargs...)
    field = inputs[:field]
    payload = (; class = "debug-product", norm = sum(abs, field.payload.values))
    return OperationOutcome(;
        outputs = [wq_output(plan, spec, :debug, payload, WQ_DEBUG;
            references = [wq_pinned(:field, field)])],
    )
end

function apply_operation(::Val{Symbol("workload/infer")}, spec::OperationSpec, inputs; plan, kwargs...)
    evidence = inputs[:evidence]
    label = String(spec.name)
    payload = (;
        class = "inference",
        evidence = evidence.payload.class,
        label = label,
        value = label == "infer_a" ? 1.0 : 2.0,
    )
    return OperationOutcome(;
        outputs = [wq_output(plan, spec, :inference, payload, WQ_INFERENCE;
            references = [wq_pinned(:evidence, evidence)])],
        restart = RestartRequirement(;
            checkpoints = [CheckpointRef(
                evidence.object.object_id;
                content_id = evidence.object.content_id,
                revision_id = evidence.object.revision_id,
                kind = :checkpoint,
            )],
            execution_context = WQ_CTX,
        ),
    )
end

function wq_geometry_schemas()
    return wq_registry(
        (WQ_GEOMETRY, [wq_array_field(:coordinates, 2; shape = (3, nothing))]),
        (WQ_DISCRETIZATION, [wq_array_field(:connectivity, 2; shape = (nothing, nothing))]),
        (WQ_STATE, [wq_array_field(:degrees_of_freedom, 1)]),
        (WQ_FIELD, [wq_array_field(:values, 1)]),
        (WQ_CHECKPOINT, [wq_array_field(:snapshot, 1)]),
        (WQ_DEBUG, [SchemaField(:norm, LogicalType(:real))]),
    )
end

function wq_root!(id, revision, schema, payload)
    content = canonical_content_id(payload)
    object = wq_object(id, revision, schema; content = content)
    store = WorkingStore()
    store_payload!(store, object.object_id, payload; revision_id = object.revision_id)
    graph = ArchiveGraph(
        [object];
        heads = [WorkflowHead(WorkflowHeadId("wq-head"), :main, object.revision_id)],
        revisions = [RevisionRecord(object.revision_id)],
    )
    return graph, store, object
end

function wq_plan(id, spec, bindings)
    return Plan(PlanId(id); operations = [spec], bindings = bindings)
end

function wq_file_has_marker(path, marker)
    return occursin(marker, String(read(path)))
end

# Project.toml table body. The test environment does not load a TOML package.
function wq_project_section(name::AbstractString)
    text = read(joinpath(pkgdir(Episteme), "Project.toml"), String)
    head = match(Regex("(?m)^\\[$(name)\\]\\s*\$"), text)
    head === nothing && return ""
    rest = text[(head.offset + length(head.match)):end]
    nxt = findfirst(r"(?m)^\[", rest)
    return nxt === nothing ? rest : rest[1:(first(nxt) - 1)]
end

@testset "geometry-like numerical state round-trips through one archive" begin
    mktempdir() do dir
        payload = (;
            class = "geometry-like",
            coordinates = Float64[0 1 0 1; 0 0 1 1; 0 0 0 0],
            marker = WQ_MEMORY_MARKER,
        )
        graph, store, geometry = wq_root!("wq-geometry", "wq-rev-geometry", WQ_GEOMETRY, payload)
        schemas = wq_geometry_schemas()
        @test !isdefined(Episteme, :WQ_GEOMETRY)
        @test schema_kind(WQ_GEOMETRY) == Symbol("workload/geometry-like")
        @test :chunk ∉ fieldnames(LogicalArraySpec)
        @test :compression ∉ fieldnames(LogicalArraySpec)

        discretization_id = ObjectId("wq-discretization")
        discretize = OperationSpec(
            Symbol("workload/discretize");
            name = :discretize,
            inputs = (:geometry,),
            outputs = (:discretization,),
        )
        wq_commit!(graph, store, wq_plan("wq-plan-discretize", discretize, [
            PlanBinding(:geometry;
                object_id = geometry.object_id,
                revision_id = geometry.revision_id,
                content_id = geometry.content_id,
                schema = WQ_GEOMETRY,
            ),
            PlanBinding(:discretization;
                source = :discretize,
                object_id = discretization_id,
                schema = WQ_DISCRETIZATION,
            ),
        ]), "wq-rev-discretization")
        discretization = find_object(graph, discretization_id, RevisionId("wq-rev-discretization"))
        @test discretization !== nothing
        @test only(discretization.references).target.object_id == geometry.object_id
        @test only(discretization.references).target.revision_id == geometry.revision_id

        state_id = ObjectId("wq-state")
        field_id = ObjectId("wq-field")
        advance = OperationSpec(
            Symbol("workload/advance");
            name = :advance,
            inputs = (:discretization,),
            outputs = (:state, :field),
        )
        wq_commit!(graph, store, wq_plan("wq-plan-advance", advance, [
            PlanBinding(:discretization;
                object_id = discretization.object_id,
                revision_id = discretization.revision_id,
                content_id = discretization.content_id,
                schema = WQ_DISCRETIZATION,
            ),
            PlanBinding(:state; source = :advance, object_id = state_id, schema = WQ_STATE),
            PlanBinding(:field; source = :advance, object_id = field_id, schema = WQ_FIELD),
        ]), "wq-rev-state")
        state = find_object(graph, state_id, RevisionId("wq-rev-state"))
        field = find_object(graph, field_id, RevisionId("wq-rev-state"))
        @test state.content_id != field.content_id
        @test state.references[1].target == field.references[1].target

        checkpoint_id = ObjectId("wq-checkpoint")
        checkpoint_spec = OperationSpec(
            Symbol("workload/checkpoint");
            name = :checkpoint,
            inputs = (:state, :field),
            outputs = (:checkpoint,),
        )
        checkpoint_run = wq_commit!(graph, store, wq_plan("wq-plan-checkpoint", checkpoint_spec, [
            PlanBinding(:state;
                object_id = state.object_id, revision_id = state.revision_id,
                content_id = state.content_id, schema = WQ_STATE),
            PlanBinding(:field;
                object_id = field.object_id, revision_id = field.revision_id,
                content_id = field.content_id, schema = WQ_FIELD),
            PlanBinding(:checkpoint;
                source = :checkpoint, object_id = checkpoint_id, schema = WQ_CHECKPOINT),
        ]), "wq-rev-checkpoint")
        checkpoint = find_object(graph, checkpoint_id, RevisionId("wq-rev-checkpoint"))
        @test length(checkpoint.references) == 2
        @test checkpoint_run.restart !== nothing

        debug_id = ObjectId("wq-debug")
        debug_spec = OperationSpec(
            Symbol("workload/debug");
            name = :debug,
            inputs = (:field,),
            outputs = (:debug,),
        )
        debug_run = wq_commit!(graph, store, wq_plan("wq-plan-debug", debug_spec, [
            PlanBinding(:field;
                object_id = field.object_id, revision_id = field.revision_id,
                content_id = field.content_id, schema = WQ_FIELD),
            PlanBinding(:debug; source = :debug, object_id = debug_id, schema = WQ_DEBUG),
        ]), "wq-rev-debug")
        debug = find_object(graph, debug_id, RevisionId("wq-rev-debug"))
        derived = DerivedArtifactRecord(
            debug.object_id, debug.revision_id, :debug;
            inputs = [DerivedInputRef(field.object_id, field.revision_id; content_id = field.content_id)],
            run_id = debug_run.id,
            activity_id = only(debug_run.activities).id,
            operation = Symbol("workload/debug"),
            parameters = (; probe = "residual"),
            schema = WQ_DEBUG,
            retention = :debug,
            value_shape = (1,),
        )
        @test isvalid(validate([derived], graph))
        @test isempty(derived_ancestry(derived, [derived]))
        @test count(object -> object.content_id == geometry.content_id, graph.objects) == 1

        parent = checkout(graph, geometry.revision_id)
        child = checkout(graph, RevisionId("wq-rev-debug"))
        @test select(parent, geometry.object_id) !== nothing
        @test select(parent, debug.object_id) === nothing
        @test select(child, geometry.object_id).availability === :envelope_only
        @test select(child, debug.object_id).content_id == debug.content_id
        @test fetch_payload(store, geometry.object_id; revision_id = geometry.revision_id).marker ==
            WQ_MEMORY_MARKER

        alternate = branch_from(geometry.revision_id;
            id = WorkflowHeadId("wq-head-alt"), name = :alternate)
        @test alternate.revision_id == geometry.revision_id
        branched = ArchiveGraph(
            graph.objects;
            heads = [graph.heads; alternate],
            revisions = graph.revisions,
            runs = graph.runs,
            events = graph.events,
            writes = graph.writes,
        )
        @test find_head(branched, :alternate).revision_id == geometry.revision_id
        @test find_head(graph, :main).revision_id == RevisionId("wq-rev-debug")

        dangling = ArchiveGraph(
            [wq_object("wq-dangling", "wq-rev-geometry", WQ_FIELD;
                content = canonical_content_id((; class = "dangling")),
                references = [ArchiveReference(:missing, ObjectId("wq-absent");
                    revision_id = geometry.revision_id)])];
            revisions = [RevisionRecord(geometry.revision_id)],
        )
        dangling_path = joinpath(dir, "dangling.ah5")
        @test_throws ArgumentError write_state_archive(dangling_path, dangling; schemas = schemas)
        @test !ispath(dangling_path)

        path = joinpath(dir, "geometry.ah5")
        write_derived_archive(path, graph, [derived];
            schemas = schemas, archive_id = "wq-geometry-archive")
        @test !wq_file_has_marker(path, WQ_MEMORY_MARKER)
        core = inspect_archive(path)
        @test core.identified
        @test isvalid(validate(core))
        @test any(listing -> listing.schema == WQ_GEOMETRY, core.schemas)
        listing = only(listing for listing in core.schemas if listing.schema == WQ_GEOMETRY)
        @test listing.fields[1].name === :coordinates
        @test listing.fields[1].element.kind === :real
        @test listing.fields[1].shape == (3, nothing)

        view = inspect_archive(path, ArchiveDerivedHistory)
        @test isvalid(view)
        restored = reconstruct_graph(view)
        @test find_object(restored, geometry.object_id, geometry.revision_id).content_id ==
            geometry.content_id
        @test find_object(restored, checkpoint.object_id, checkpoint.revision_id) !== nothing
        @test only(view.artifacts).role === :debug
        @test only(view.artifacts).inputs[1].content_id == field.content_id

        manifest = inspect(view, RevisionId("wq-rev-checkpoint"))
        @test isready(readiness(manifest, PipelineTarget(:inspect)))
        @test isready(readiness(manifest, PipelineTarget(:replay)))
        @test isready(readiness(manifest, PipelineTarget(:restart)))
        @test isready(readiness(manifest, PipelineTarget(:rerun)))
        capsule = plan_capsule(graph, RevisionId("wq-rev-checkpoint"), schemas; target = :restart)
        @test isvalid(capsule)
        @test capsule.ready

        coordinates = payload.coordinates
        triangles = Int32[0 1; 1 3; 2 2]
        samples = Float64[1.0, 2.0, 3.0, 4.0]
        chosen = Int32[0]
        JLD2.jldopen(path, "r+") do file
            file["data/coordinates"] = coordinates
            file["data/triangles"] = triangles
            file["data/samples"] = samples
            file["data/chosen"] = chosen
        end
        object_ref = ObjectRef(geometry.object_id; revision_id = geometry.revision_id)
        datasets = (
            coordinates = XdmfDataset("/data/coordinates", object_ref, geometry.content_id;
                content_id = canonical_content_id(coordinates)),
            triangles = XdmfDataset("/data/triangles", object_ref, geometry.content_id;
                content_id = canonical_content_id(triangles)),
            samples = XdmfDataset("/data/samples", object_ref, geometry.content_id;
                content_id = canonical_content_id(samples)),
            chosen = XdmfDataset("/data/chosen", object_ref, geometry.content_id;
                content_id = canonical_content_id(chosen)),
        )
        grid = XdmfGrid("fixture-grid", datasets.coordinates, datasets.triangles;
            cells = 2,
            attributes = (XdmfAttribute("samples", datasets.samples),),
            sets = (XdmfSet("chosen-cells", datasets.chosen),))
        projection = xdmf_projection(XdmfCollection("levels", (grid,)))
        report = inspect_xdmf_view(path, projection)
        @test isvalid(report)
        @test isready(readiness(report, PipelineTarget(:xdmf)))
        xdmf_path = joinpath(dir, "levels.xmf")
        @test isvalid(write_xdmf_view(xdmf_path, path, projection))
        @test occursin("chosen-cells", read(xdmf_path, String))
    end
end

@testset "experimental evidence stays distinct from later inference" begin
    mktempdir() do dir
        attachment_path = joinpath(dir, "provider.bin")
        attachment_bytes = zeros(UInt8, 48_000)
        marker = codeunits(WQ_EXTERNAL_MARKER)
        attachment_bytes[1:length(marker)] .= marker
        write(attachment_path, attachment_bytes)
        attachment_id = ObjectId("wq-attachment")
        attachment_content = external_file_content_id(attachment_path)
        requirement = ExternalRequirement(
            attachment_id;
            content_id = attachment_content,
            artifact = ArtifactRef(:blob; path = attachment_path, description = "opaque provider bytes"),
        )
        record = capture_external_integrity(requirement; sample_bytes = 1024, sample_count = 3)
        @test record.content_id == attachment_content
        @test isvalid(verify_external(record; level = :metadata))
        @test verify_external(record; level = :metadata).bytes_checked == 0
        sampled = verify_external(record; level = :sample)
        @test isvalid(sampled)
        @test 0 < sampled.bytes_checked < filesize(attachment_path)
        full = verify_external(record; level = :full)
        @test isvalid(full)
        @test full.bytes_checked == filesize(attachment_path)

        evidence_payload = (; class = "evidence", observations = Float64[1, 3, 5, 7, 9])
        graph, store, evidence = wq_root!("wq-evidence", "wq-rev-evidence", WQ_EVIDENCE, evidence_payload)
        evidence_with_attachment = wq_object(
            evidence.object_id, evidence.revision_id, WQ_EVIDENCE;
            content = evidence.content_id,
            references = [ArchiveReference(:attachment, attachment_id)],
        )
        graph.objects[1] = evidence_with_attachment
        evidence = evidence_with_attachment
        document = capture_portable(
            DocumentId("wq-evidence-document"),
            SemanticNode(Symbol("workload/evidence"); class = "evidence", points = 5);
            metadata = (; authoritative = true),
        )
        @test isvalid(validate(document))
        @test canonical_content_id(from_namedtuple(PortableSemanticDocument, to_namedtuple(document))) ==
            canonical_content_id(document)
        @test is_portable_value(evidence_payload.observations)
        @test !is_portable_value(sqrt)

        schemas = wq_registry(
            (WQ_EVIDENCE, [wq_array_field(:observations, 1)]),
            (WQ_INFERENCE, [SchemaField(:value, LogicalType(:real))]),
        )
        refused = joinpath(dir, "missing-external.ah5")
        @test_throws ArgumentError write_event_archive(refused, graph; schemas = schemas)
        @test !ispath(refused)

        function infer_plan(name, object_id)
            spec = OperationSpec(
                Symbol("workload/infer");
                name = name,
                inputs = (:evidence,),
                outputs = (:inference,),
            )
            return spec, wq_plan("wq-plan-" * String(name), spec, [
                PlanBinding(:evidence;
                    object_id = evidence.object_id,
                    revision_id = evidence.revision_id,
                    content_id = evidence.content_id,
                    schema = WQ_EVIDENCE,
                ),
                PlanBinding(:inference; source = name, object_id = object_id, schema = WQ_INFERENCE),
            ])
        end

        _, plan_a = infer_plan(:infer_a, ObjectId("wq-inference-a"))
        run_a = wq_commit!(graph, store, plan_a, "wq-rev-inference-a")
        inference_a = find_object(graph, ObjectId("wq-inference-a"), RevisionId("wq-rev-inference-a"))
        @test only(inference_a.references).target.revision_id == evidence.revision_id

        alternate = branch_from(evidence.revision_id;
            id = WorkflowHeadId("wq-head-alt"), name = :alternate)
        push!(graph.heads, alternate)
        spec_b = OperationSpec(
            Symbol("workload/infer");
            name = :infer_b,
            inputs = (:evidence,),
            outputs = (:inference,),
        )
        plan_b = Plan(PlanId("wq-plan-infer-b"); operations = [spec_b], bindings = [
            PlanBinding(:evidence;
                object_id = evidence.object_id,
                revision_id = evidence.revision_id,
                content_id = evidence.content_id,
                schema = WQ_EVIDENCE,
            ),
            PlanBinding(:inference;
                source = :infer_b, object_id = ObjectId("wq-inference-b"), schema = WQ_INFERENCE),
        ])
        run_b = execute!(
            graph, plan_b;
            head = :alternate,
            store = store,
            software_environment = WQ_ENV,
            execution_context = WQ_CTX,
            agent_id = WQ_AGENT,
        )
        @test run_b.revision_id === nothing
        commit!(graph, run_b.id; head = :alternate, store = store,
            revision_id = RevisionId("wq-rev-inference-b"))
        @test find_head(graph, :main).revision_id == RevisionId("wq-rev-inference-a")
        @test find_head(graph, :alternate).revision_id == RevisionId("wq-rev-inference-b")
        inference_b = find_object(graph, ObjectId("wq-inference-b"), RevisionId("wq-rev-inference-b"))
        @test count(object -> object.object_id == evidence.object_id, graph.objects) == 1
        @test inference_a.content_id != inference_b.content_id
        @test !isvalid(compare_reproduction(inference_a.content_id, inference_b.content_id))
        @test isvalid(compare_reproduction(evidence.content_id, evidence.content_id))
        shared = checkout(graph, inference_a.revision_id; externals = [requirement])
        other = checkout(graph, inference_b.revision_id; externals = [requirement])
        @test select(shared, evidence.object_id).content_id == select(other, evidence.object_id).content_id
        @test select(shared, inference_b.object_id) === nothing
        @test select(shared, attachment_id).availability === :external_required

        uncertain_id = RunId("wq-uncertain-side-effect")
        push!(graph.runs, RunRecord(uncertain_id; status = :uncertain))
        push!(graph.writes, WriteTransaction(;
            scope = :run, phase = :uncertain, sequence = 1, run_id = uncertain_id))
        push!(graph.events, EventRecord(
            :external_effect, uncertain_id;
            sequence = 1, source = "provider", severity = :error,
            message = "external side effect outcome is unknown",
            payload = (; outcome = "unknown"),
        ))
        recovery = recover_writes!(graph)
        @test !isvalid(recovery)
        @test any(diagnostic -> diagnostic.code === :uncertain_side_effect, recovery.diagnostics)
        @test find_run(graph, uncertain_id).status === :uncertain
        @test find_run(graph, uncertain_id).revision_id === nothing
        @test !isready(readiness(graph, PipelineTarget(:commit; run_id = uncertain_id)))

        interrupt_spec = OperationSpec(
            Symbol("workload/infer");
            name = :infer_a,
            inputs = (:evidence,),
            outputs = (:inference,),
        )
        interrupt_plan = wq_plan("wq-plan-interrupt", interrupt_spec, [
            PlanBinding(:evidence;
                object_id = evidence.object_id,
                revision_id = evidence.revision_id,
                content_id = evidence.content_id,
                schema = WQ_EVIDENCE,
            ),
            PlanBinding(:inference;
                source = :infer_a, object_id = ObjectId("wq-inference-interrupted"), schema = WQ_INFERENCE),
        ])
        @test_throws ExecutionInterrupted execute!(
            graph, interrupt_plan;
            head = :main, store = store, interrupt_after = :before_operation,
            software_environment = WQ_ENV,
        )
        interrupted = only(run for run in graph.runs if run.status === :interrupted)
        @test interrupted.revision_id === nothing
        recover_writes!(graph)
        @test find_run(graph, interrupted.id).status === :interrupted
        @test find_run(graph, interrupted.id).revision_id === nothing
        @test find_revision(graph, RevisionId("wq-rev-inference-a")) !== nothing

        native = EventRecord(
            :measured, run_a.id;
            sequence = 1, source = "qualification",
            revision_id = inference_a.revision_id,
            payload = (; values = Float64[1.5, 2.5, 3.5]),
        )
        push!(graph.events, native)
        refused_native = ArchiveGraph(
            graph.objects;
            heads = graph.heads,
            revisions = graph.revisions,
            runs = graph.runs,
            events = [EventRecord(:measured, run_a.id; sequence = 1, source = "bad",
                payload = (; value = WQNotPortable(1)))],
        )
        bad_path = joinpath(dir, "not-portable.ah5")
        @test_throws ArgumentError write_event_archive(bad_path, refused_native; schemas = schemas)
        @test !ispath(bad_path)

        path = joinpath(dir, "evidence.ah5")
        write_event_archive(path, graph; schemas = schemas, externals = [requirement],
            archive_id = "wq-evidence-archive")
        @test !wq_file_has_marker(path, WQ_EXTERNAL_MARKER)
        view = inspect_archive(path, ArchiveEventHistory)
        @test isvalid(view)
        reopened = inspect(view, inference_a.revision_id)
        @test select(reopened, attachment_id).availability === :external_required
        @test select(reopened, evidence.object_id).availability === :envelope_only
        @test isready(readiness(reopened, PipelineTarget(:inspect)))
        @test !isready(readiness(reopened, PipelineTarget(:replay)))
        @test isready(readiness(reopened, PipelineTarget(:restart)))
        @test !isready(readiness(reopened, PipelineTarget(:rerun)))
        @test any(diagnostic -> diagnostic.code === :external_content_required,
            readiness(reopened, PipelineTarget(:replay)).diagnostics)
        restored_payload = only(event.payload for event in view.events if event.source == "qualification")
        @test canonical_content_id(restored_payload) == canonical_content_id(native.payload)
        restored_graph = reconstruct_graph(view)
        @test find_run(restored_graph, uncertain_id).status === :uncertain
        @test find_run(restored_graph, uncertain_id).revision_id === nothing
        @test find_run(restored_graph, interrupted.id).status === :interrupted
        @test find_run(restored_graph, run_a.id).revision_id == inference_a.revision_id

        tampered = attachment_bytes
        tampered[end] = 0x5a
        write(attachment_path, tampered)
        mismatched = verify_external(record; level = :full)
        @test !isvalid(mismatched)
        @test any(diagnostic -> diagnostic.code === :external_hash_mismatch, mismatched.diagnostics)
        @test_throws ArgumentError capture_external_integrity(requirement)
    end
end

@testset "distributed checkpoints reuse metadata without a gathered vector" begin
    mktempdir() do dir
        problem_payload = (; class = "problem-metadata", name = "shared-problem")
        problem_content = canonical_content_id(problem_payload)
        problem = wq_object("wq-problem", "wq-rev-problem", WQ_PROBLEM; content = problem_content)
        shard_a_values = Float64[1, 2, 3]
        shard_b_values = Float64[4, 5]
        gathered = vcat(shard_a_values, shard_b_values)
        shard_a = wq_object("wq-shard-a", "wq-rev-checkpoint", WQ_SHARD;
            content = canonical_content_id(shard_a_values),
            references = [ArchiveReference(:problem, problem.object_id; revision_id = problem.revision_id)])
        shard_b = wq_object("wq-shard-b", "wq-rev-checkpoint", WQ_SHARD;
            content = canonical_content_id(shard_b_values),
            references = [ArchiveReference(:problem, problem.object_id; revision_id = problem.revision_id)])
        run_id = RunId("wq-distributed-run")
        activity_id = ActivityId("wq-distributed-activity")
        activity = ActivityRecord(
            activity_id, run_id, Symbol("workload/checkpoint-shards");
            used = [ArchiveReference(:problem, problem.object_id; revision_id = problem.revision_id)],
            generated = [
                ArchiveReference(:shard, shard_a.object_id; revision_id = shard_a.revision_id),
                ArchiveReference(:shard, shard_b.object_id; revision_id = shard_b.revision_id),
            ],
        )
        run = RunRecord(
            run_id;
            plan_id = PlanId("wq-plan-shards"),
            revision_id = shard_a.revision_id,
            status = :completed,
            software_environment = WQ_ENV,
            execution_context = WQ_CTX,
            agent_id = WQ_AGENT,
            activities = [activity],
            restart = RestartRequirement(;
                checkpoints = [
                    CheckpointRef(shard_a.object_id; content_id = shard_a.content_id,
                        revision_id = shard_a.revision_id),
                    CheckpointRef(shard_b.object_id; content_id = shard_b.content_id,
                        revision_id = shard_b.revision_id),
                ],
                execution_context = WQ_CTX,
                from_activity_id = activity_id,
            ),
        )
        heavy_path = joinpath(dir, "gathered.bin")
        heavy = zeros(UInt8, 1 << 20)
        marker = codeunits(WQ_EXTERNAL_MARKER)
        heavy[1:length(marker)] .= marker
        write(heavy_path, heavy)
        heavy_id = ObjectId("wq-gathered-vector")
        heavy_content = external_file_content_id(heavy_path)
        requirement = ExternalRequirement(
            heavy_id;
            content_id = heavy_content,
            artifact = ArtifactRef(:bin; path = heavy_path, description = "not gathered into the archive"),
        )
        heavy_record = capture_external_integrity(requirement; sample_bytes = 4096, sample_count = 3)
        shard_a = wq_object(shard_a.object_id, shard_a.revision_id, WQ_SHARD;
            content = shard_a.content_id,
            run = run_id,
            references = [
                ArchiveReference(:problem, problem.object_id; revision_id = problem.revision_id),
                ArchiveReference(:gathered, heavy_id),
            ])
        graph = ArchiveGraph(
            [problem, shard_a, shard_b];
            heads = [WorkflowHead(WorkflowHeadId("wq-head"), :main, shard_a.revision_id)],
            revisions = [
                RevisionRecord(problem.revision_id),
                RevisionRecord(shard_a.revision_id; parents = [problem.revision_id],
                    run_id = run_id, plan_id = PlanId("wq-plan-shards")),
            ],
            runs = [run],
            writes = [WriteTransaction(;
                scope = :archive, phase = :committed, sequence = 1, run_id = run_id)],
        )
        @test shard_a.schema == shard_b.schema
        @test shard_a.content_id != shard_b.content_id
        @test shard_a.content_id != canonical_content_id(gathered)
        @test count(object -> object.content_id == problem_content, graph.objects) == 1
        shard_schema = wq_definition(WQ_SHARD, [wq_array_field(:values, 1; shape = (nothing,))])
        @test shard_schema.fields[1].shape == (nothing,)
        @test :chunk ∉ fieldnames(SchemaField)
        @test !occursin("HDF5", wq_project_section("deps"))
        @test !occursin("HDF5", wq_project_section("weakdeps"))
        @test !occursin("HDF5", wq_project_section("extensions"))
        @test !occursin("EpistemeHDF5Ext", wq_project_section("extensions"))
        @test !isempty(wq_project_section("deps"))

        schemas = wq_registry(
            (WQ_PROBLEM, [SchemaField(:name, LogicalType(:string))]),
            (WQ_SHARD, [wq_array_field(:values, 1; shape = (nothing,))]),
        )
        missing = joinpath(dir, "dangling-gathered.ah5")
        @test_throws ArgumentError write_run_archive(missing, graph; schemas = schemas)
        @test !ispath(missing)

        path = joinpath(dir, "checkpoints.ah5")
        started = time_ns()
        write_run_archive(path, graph; schemas = schemas, externals = [requirement],
            archive_id = "wq-checkpoint-archive")
        write_ns = time_ns() - started
        @test write_ns >= 0
        @test !wq_file_has_marker(path, WQ_EXTERNAL_MARKER)
        @test filesize(path) < filesize(heavy_path)

        before = mtime(heavy_path)
        checkout_started = time_ns()
        manifest = checkout(graph, shard_a.revision_id; externals = [requirement])
        checkout_ns = time_ns() - checkout_started
        @test checkout_ns >= 0
        @test mtime(heavy_path) == before
        @test select(manifest, problem.object_id).availability === :envelope_only
        @test select(manifest, shard_a.object_id).availability === :envelope_only
        @test select(manifest, heavy_id).availability === :external_required
        @test isready(readiness(manifest, PipelineTarget(:inspect)))
        @test isready(readiness(manifest, PipelineTarget(:restart)))
        @test !isready(readiness(manifest, PipelineTarget(:replay)))
        integrity = integrity_manifest(
            graph, shard_a.revision_id, schemas;
            externals = [requirement],
            external_integrity = [heavy_record],
            level = :metadata,
        )
        @test isvalid(integrity)
        external_row = only(row for row in integrity.dependencies if row.kind === :external)
        @test external_row.content_id == heavy_content
        @test external_row.availability === :external_required
        view = inspect_archive(path, ArchiveRunHistory)
        @test isvalid(view)
        reopened = inspect(view, shard_a.revision_id)
        @test select(reopened, heavy_id).content_id == heavy_content
        @test select(reopened, shard_a.object_id).availability === :envelope_only
        @test isready(readiness(reopened, PipelineTarget(:restart)))
        @test !isready(readiness(reopened, PipelineTarget(:replay)))
    end
end

@testset "performance-research state keeps large artifacts outside the archive" begin
    mktempdir() do dir
        weights_path = joinpath(dir, "weights.bin")
        weights = zeros(UInt8, 1 << 20)
        marker = codeunits(WQ_EXTERNAL_MARKER)
        weights[1:length(marker)] .= marker
        weights[end] = 0x11
        write(weights_path, weights)
        weights_content = external_file_content_id(weights_path)
        weights_object = wq_object("wq-weights", "wq-rev-weights", WQ_WEIGHTS; content = weights_content)
        requirement = ExternalRequirement(
            weights_object.object_id;
            content_id = weights_content,
            artifact = ArtifactRef(:bin; path = weights_path, description = "external weights"),
        )
        identity = capture_external_integrity(requirement; sample_bytes = 4096, sample_count = 3)
        @test identity.content_id == weights_object.content_id

        selected_payload = (; class = "measurement", candidate = "selected", loss = 0.25)
        refuted_payload = (; class = "measurement", candidate = "refuted", loss = 4.0)
        selected = wq_object("wq-selected", "wq-rev-search", WQ_MEASUREMENT;
            content = canonical_content_id(selected_payload),
            references = [ArchiveReference(:weights, weights_object.object_id;
                revision_id = weights_object.revision_id)])
        refuted = wq_object("wq-refuted", "wq-rev-search", WQ_CANDIDATE;
            content = canonical_content_id(refuted_payload),
            references = [ArchiveReference(:weights, weights_object.object_id;
                revision_id = weights_object.revision_id)])
        model = wq_object("wq-cost-model", "wq-rev-search", WQ_COST;
            content = canonical_content_id((; class = "cost-model", selected = selected_payload.loss)),
            references = [ArchiveReference(:measurement, selected.object_id;
                revision_id = selected.revision_id)])
        run_id = RunId("wq-search-run")
        activity_id = ActivityId("wq-search-activity")
        activity = ActivityRecord(
            activity_id, run_id, Symbol("workload/select");
            used = [ArchiveReference(:weights, weights_object.object_id;
                revision_id = weights_object.revision_id)],
            generated = [
                ArchiveReference(:selected, selected.object_id; revision_id = selected.revision_id),
                ArchiveReference(:refuted, refuted.object_id; revision_id = refuted.revision_id),
                ArchiveReference(:model, model.object_id; revision_id = model.revision_id),
            ],
        )
        run = RunRecord(
            run_id;
            revision_id = selected.revision_id,
            status = :completed,
            software_environment = WQ_ENV,
            execution_context = WQ_CTX,
            agent_id = WQ_AGENT,
            activities = [activity],
        )
        graph = ArchiveGraph(
            [weights_object, selected, refuted, model];
            heads = [WorkflowHead(WorkflowHeadId("wq-head"), :main, selected.revision_id)],
            revisions = [
                RevisionRecord(weights_object.revision_id),
                RevisionRecord(selected.revision_id; parents = [weights_object.revision_id],
                    run_id = run_id),
            ],
            runs = [run],
            events = [EventRecord(:measured, run_id;
                activity_id = activity_id, sequence = 1, source = "qualification",
                revision_id = selected.revision_id,
                payload = (; loss = selected_payload.loss, candidate = "selected"))],
            writes = [WriteTransaction(;
                scope = :archive, phase = :committed, sequence = 1, run_id = run_id)],
        )
        records = [
            DerivedArtifactRecord(
                refuted.object_id, refuted.revision_id, :derived;
                inputs = [DerivedInputRef(weights_object.object_id, weights_object.revision_id;
                    content_id = weights_content)],
                run_id = run_id, activity_id = activity_id,
                operation = Symbol("workload/select"),
                parameters = (; candidate = "refuted"),
                schema = WQ_CANDIDATE,
                status = :failed,
                retention = :forensic,
            ),
            DerivedArtifactRecord(
                model.object_id, model.revision_id, :derived;
                inputs = [DerivedInputRef(selected.object_id, selected.revision_id;
                    content_id = selected.content_id)],
                run_id = run_id, activity_id = activity_id,
                operation = Symbol("workload/select"),
                parameters = (; candidate = "selected"),
                schema = WQ_COST,
                status = :complete,
                retention = :pinned,
                artifact = ArtifactRef(:bin; path = weights_path, description = "weights stay outside"),
            ),
        ]
        @test count(object -> object.content_id == weights_content, graph.objects) == 1
        schemas = wq_registry(
            (WQ_WEIGHTS, [SchemaField(:byte_size, LogicalType(:integer))]),
            (WQ_MEASUREMENT, [SchemaField(:loss, LogicalType(:real))]),
            (WQ_CANDIDATE, [SchemaField(:loss, LogicalType(:real))]),
            (WQ_COST, [SchemaField(:loss, LogicalType(:real))]),
        )
        path = joinpath(dir, "search.ah5")
        write_derived_archive(path, graph, records; schemas = schemas, archive_id = "wq-search-archive")
        @test !wq_file_has_marker(path, WQ_EXTERNAL_MARKER)
        @test filesize(path) < filesize(weights_path)
        archived = read(path)
        function hot(x, y)
            total = 0.0
            @inbounds for index in eachindex(x, y)
                total += x[index] * y[index]
            end
            return total
        end
        left = rand(64)
        right = rand(64)
        hot(left, right)
        started = time_ns()
        total = 0.0
        for _ in 1:30
            total += hot(left, right)
        end
        hot_ns = time_ns() - started
        @test hot_ns >= 0
        @test isfinite(total)
        @test read(path) == archived

        view = inspect_archive(path, ArchiveDerivedHistory)
        @test isvalid(view)
        @test count(record -> record.status === :failed, view.artifacts) == 1
        @test count(record -> record.status === :complete, view.artifacts) == 1
        reopened = inspect(view, selected.revision_id)
        @test select(reopened, weights_object.object_id).content_id == weights_content
        @test select(reopened, weights_object.object_id).availability === :envelope_only
        weights[end] = 0x22
        write(weights_path, weights)
        failed = verify_external(identity; level = :full)
        @test !isvalid(failed)
        @test any(diagnostic -> diagnostic.code === :external_hash_mismatch, failed.diagnostics)
        metadata_only = verify_external(identity; level = :metadata)
        @test metadata_only.bytes_checked == 0
    end
end
