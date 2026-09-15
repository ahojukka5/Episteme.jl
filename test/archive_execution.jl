# In-memory execute / stage / commit lifecycle (#107).

const FIX_NS = ArchiveNamespace(:fixture; display_name = "Fixture.jl")
const GEOM_SCHEMA = SchemaRef(:fixture, "geometry", "1.0.0")
const MESH_SCHEMA = SchemaRef(:fixture, "mesh", "1.0.0")
const FIELD_SCHEMA = SchemaRef(:fixture, "field", "1.0.0")

struct FixtureGeometry
    token::String
    n::Int
end

struct FixtureMesh
    token::String
    geometry_token::String
end

struct FixtureField
    token::String
    mesh_token::String
end

import Episteme: apply_operation, report, validate, readiness

function validate(g::FixtureGeometry)
    ok = g.n > 0
    return ValidationReport(
        :geometry,
        ok,
        ok ? DiagnosticMessage[] : [error_diagnostic(:invalid_size, "geometry size must be positive")],
        (; token = g.token),
    )
end

function readiness(g::FixtureGeometry, target::PipelineTarget)
    ready = g.n > 0 && target.name === :discretize
    return ReadinessReport(
        :geometry,
        target,
        ready,
        ready ? DiagnosticMessage[] :
            [error_diagnostic(:not_ready, "geometry is not ready for :$(target.name)")],
        (; token = g.token),
    )
end

function apply_operation(::Val{Symbol("fixture/make-geometry")}, spec::OperationSpec, inputs; plan, kwargs...)
    payload = FixtureGeometry("g1", 4)
    return OperationOutcome(;
        outputs = [staged_result(
            plan_output_id(plan, spec, :geometry),
            payload;
            namespace = FIX_NS,
            kind = schema_kind(GEOM_SCHEMA),
            schema = GEOM_SCHEMA,
            content_id = ContentId("geom-$(payload.token)"),
        )],
    )
end

function apply_operation(::Val{Symbol("fixture/discretize")}, spec::OperationSpec, inputs; plan, kwargs...)
    geom = inputs[:geometry].payload
    geom isa FixtureGeometry || return OperationOutcome(;
        status = :failed,
        message = "missing geometry payload",
        diagnostics = [error_diagnostic(:missing_input, "geometry payload is missing")],
    )
    payload = FixtureMesh("m1", geom.token)
    geom_obj = inputs[:geometry].object
    refs = ArchiveReference[]
    if geom_obj !== nothing
        push!(refs, ArchiveReference(:geometry, geom_obj.object_id; revision_id = geom_obj.revision_id))
    end
    return OperationOutcome(;
        outputs = [staged_result(
            plan_output_id(plan, spec, :mesh),
            payload;
            namespace = FIX_NS,
            kind = schema_kind(MESH_SCHEMA),
            schema = MESH_SCHEMA,
            content_id = ContentId("mesh-$(payload.token)-$(payload.geometry_token)"),
            references = refs,
        )],
    )
end

function apply_operation(::Val{Symbol("fixture/solve")}, spec::OperationSpec, inputs; plan, kwargs...)
    mesh = inputs[:mesh].payload
    mesh isa FixtureMesh || return OperationOutcome(;
        status = :failed,
        message = "missing mesh payload",
        diagnostics = [error_diagnostic(:missing_input, "mesh payload is missing")],
    )
    payload = FixtureField("u1", mesh.token)
    mesh_obj = inputs[:mesh].object
    staged_mesh = inputs[:mesh].staged
    refs = ArchiveReference[]
    if mesh_obj !== nothing
        push!(refs, ArchiveReference(:mesh, mesh_obj.object_id; revision_id = mesh_obj.revision_id))
    elseif staged_mesh !== nothing
        push!(refs, ArchiveReference(:mesh, staged_mesh.object_id))
    end
    return OperationOutcome(;
        outputs = [staged_result(
            plan_output_id(plan, spec, :field),
            payload;
            namespace = FIX_NS,
            kind = schema_kind(FIELD_SCHEMA),
            schema = FIELD_SCHEMA,
            content_id = ContentId("field-$(payload.token)-$(payload.mesh_token)"),
            references = refs,
        )],
    )
end

function apply_operation(::Val{Symbol("fixture/boom")}, spec::OperationSpec, inputs; kwargs...)
    return OperationOutcome(; status = :failed, message = "solver diverged")
end

function _root_geometry(;
    object = ID_GEOM,
    revision = REV_1,
    content = "geom-g0",
    token = "g0",
    n = 4,
)
    obj = ArchiveObject(
        ObjectId(object),
        RevisionId(revision);
        content_id = ContentId(content),
        namespace = FIX_NS,
        kind = schema_kind(GEOM_SCHEMA),
        schema = GEOM_SCHEMA,
    )
    store = WorkingStore()
    store_payload!(store, obj.object_id, FixtureGeometry(token, n); revision_id = obj.revision_id)
    return obj, store
end

function _head(revision = REV_1)
    return WorkflowHead(WorkflowHeadId("head-main"), :main, RevisionId(revision))
end

@testset "operation ports and plan order" begin
    geom = OperationSpec(
        Symbol("fixture/make-geometry");
        name = :geometry,
        outputs = (:geometry,),
        output_ports = [OperationPort(:geometry; schema = GEOM_SCHEMA, kind = schema_kind(GEOM_SCHEMA))],
    )
    disc = OperationSpec(
        Symbol("fixture/discretize");
        name = :discretize,
        inputs = (:geometry,),
        outputs = (:mesh,),
        input_ports = [OperationPort(:geometry; schema = GEOM_SCHEMA)],
        readiness_target = :discretize,
    )
    solve = OperationSpec(
        Symbol("fixture/solve");
        name = :solve,
        inputs = (:mesh,),
        outputs = (:field,),
    )
    plan = Plan(
        PlanId("plan-geo-mesh-solve");
        operations = [solve, disc, geom],
        bindings = [
            PlanBinding(:geometry; source = :geometry, object_id = ObjectId(ID_GEOM)),
            PlanBinding(:mesh; source = :discretize, object_id = ObjectId(ID_MESH)),
            PlanBinding(:field; source = :solve, object_id = ObjectId(ID_FIELD)),
        ],
    )
    @test isvalid(validate(plan))
    order = plan_operation_order(plan)
    @test [spec.name for spec in order] == [:geometry, :discretize, :solve]
    @test [b.role for b in plan_roots(plan)] == Symbol[]
    @test to_namedtuple(plan).bindings[1].role === :geometry
    @test report(plan).metadata.cyclic == false
    @test isready(readiness(plan, PipelineTarget(:execute)))
end

@testset "object revision and content identity stay distinct" begin
    spec = OperationSpec(Symbol("fixture/solve"); inputs = (:mesh,), outputs = (:field,))
    @test spec.kind != Symbol(spec.inputs[1])
    @test ObjectId("same") != RevisionId("same")
    @test ObjectId("same") != ContentId("same")
    @test canonical_content_id(SchemaRef(:fixture, "geometry", "1.0.0")) isa ContentId
end

@testset "missing and wrong-revision inputs fail before execute" begin
    parent = ArchiveObject(
        ObjectId(ID_GEOM),
        RevisionId(REV_1);
        content_id = ContentId("geom-g0"),
        namespace = FIX_NS,
        kind = schema_kind(GEOM_SCHEMA),
        schema = GEOM_SCHEMA,
    )
    newer = ArchiveObject(
        ObjectId(ID_GEOM),
        RevisionId(REV_2);
        content_id = ContentId("geom-g1"),
        namespace = FIX_NS,
        kind = schema_kind(GEOM_SCHEMA),
        schema = GEOM_SCHEMA,
    )
    graph = ArchiveGraph(
        [parent, newer];
        heads = [_head(REV_2)],
        revisions = [
            RevisionRecord(RevisionId(REV_1)),
            RevisionRecord(RevisionId(REV_2); parents = [RevisionId(REV_1)]),
        ],
    )
    disc = OperationSpec(
        Symbol("fixture/discretize");
        name = :discretize,
        inputs = (:geometry,),
        outputs = (:mesh,),
        input_ports = [OperationPort(:geometry; schema = GEOM_SCHEMA)],
    )
    missing = Plan(
        PlanId("plan-missing");
        operations = [disc],
        bindings = [PlanBinding(:geometry; object_id = ObjectId(ID_MESH))],
    )
    missing_ready = readiness(missing, graph, PipelineTarget(:execute; head = graph.heads[1]))
    @test !isready(missing_ready)
    @test any(d -> d.code === :unresolved_reference, missing_ready.diagnostics)

    stale = Plan(
        PlanId("plan-stale");
        operations = [disc],
        bindings = [PlanBinding(
            :geometry;
            object_id = ObjectId(ID_GEOM),
            revision_id = RevisionId(REV_1),
            content_id = ContentId("geom-g0"),
        )],
    )
    stale_ready = readiness(stale, graph, PipelineTarget(:execute; head = graph.heads[1]))
    @test !isready(stale_ready)
    @test any(d -> d.code === :wrong_revision, stale_ready.diagnostics)
    msg = only(d.message for d in stale_ready.diagnostics if d.code === :wrong_revision)
    @test occursin("workflow head :main", msg)
    @test occursin(REV_1, msg)
    @test occursin(REV_2, msg)

    content = Plan(
        PlanId("plan-content");
        operations = [disc],
        bindings = [PlanBinding(
            :geometry;
            object_id = ObjectId(ID_GEOM),
            revision_id = RevisionId(REV_2),
            content_id = ContentId("geom-g0"),
        )],
    )
    content_ready = readiness(content, graph, PipelineTarget(:execute; head = graph.heads[1]))
    @test !isready(content_ready)
    @test any(d -> d.code === :stale_content, content_ready.diagnostics)
end

@testset "successful geometry-mesh-solve execute stages then commit" begin
    geom, store = _root_geometry()
    disc = OperationSpec(
        Symbol("fixture/discretize");
        name = :discretize,
        inputs = (:geometry,),
        outputs = (:mesh,),
        input_ports = [OperationPort(:geometry; schema = GEOM_SCHEMA)],
        readiness_target = :discretize,
        validation_target = :structure,
    )
    solve = OperationSpec(
        Symbol("fixture/solve");
        name = :solve,
        inputs = (:mesh,),
        outputs = (:field,),
    )
    plan = Plan(
        PlanId("plan-ok");
        operations = [disc, solve],
        bindings = [
            PlanBinding(
                :geometry;
                object_id = geom.object_id,
                revision_id = geom.revision_id,
                content_id = geom.content_id,
                schema = GEOM_SCHEMA,
            ),
            PlanBinding(:mesh; source = :discretize, object_id = ObjectId(ID_MESH)),
            PlanBinding(:field; source = :solve, object_id = ObjectId(ID_FIELD)),
        ],
    )
    graph = ArchiveGraph(
        [geom];
        heads = [_head()],
        revisions = [RevisionRecord(RevisionId(REV_1))],
    )
    @test isready(readiness(plan, graph, PipelineTarget(:execute; head = graph.heads[1], store = store)))
    run = execute!(graph, plan; head = :main, store = store)
    @test run.status === :completed
    @test run.revision_id === nothing
    @test graph.heads[1].revision_id == RevisionId(REV_1)
    @test length(run.staged) == 2
    @test isready(readiness(graph, PipelineTarget(:commit; run_id = run.id)))
    rec = commit!(graph, run.id; head = :main, store = store, revision_id = RevisionId(REV_2))
    @test rec.id == RevisionId(REV_2)
    @test graph.heads[1].revision_id == RevisionId(REV_2)
    committed = find_run(graph, run.id)
    @test committed.revision_id == rec.id
    @test find_object(graph, ObjectId(ID_MESH), rec.id) !== nothing
    @test find_object(graph, ObjectId(ID_FIELD), rec.id) !== nothing
    mesh = find_object(graph, ObjectId(ID_MESH), rec.id)
    @test producing_run(graph, mesh) == committed
    @test producing_activity(graph, mesh).operation === Symbol("fixture/discretize")
    @test !isempty(used_inputs(graph, mesh))
    @test previous_revision(graph, geom.object_id, rec.id) == geom
    @test mesh in dependents(graph, geom.object_id, geom.revision_id) ||
        any(obj -> obj.object_id == mesh.object_id, dependents(graph, geom.object_id, geom.revision_id))
    @test any(e -> e.kind === :committed, ordered_run_events(graph, run.id))
    @test inspect(graph, rec.id).revision.id == rec.id
    @test branch_from(rec.id; id = WorkflowHeadId("head-alt"), name = :alt).revision_id == rec.id
end

@testset "operation failure leaves committed history untouched" begin
    geom, store = _root_geometry()
    boom = OperationSpec(Symbol("fixture/boom"); name = :boom)
    plan = Plan(PlanId("plan-boom"); operations = [boom])
    graph = ArchiveGraph(
        [geom];
        heads = [_head()],
        revisions = [RevisionRecord(RevisionId(REV_1))],
    )
    run = execute!(graph, plan; head = :main, store = store)
    @test run.status === :failed
    @test graph.heads[1].revision_id == RevisionId(REV_1)
    @test find_revision(graph, RevisionId(REV_2)) === nothing
    @test !isready(readiness(graph, PipelineTarget(:commit; run_id = run.id)))
end

@testset "commit validation failure does not promote staging" begin
    geom, store = _root_geometry(; n = 4)
    disc = OperationSpec(
        Symbol("fixture/discretize");
        name = :discretize,
        inputs = (:geometry,),
        outputs = (:mesh,),
    )
    plan = Plan(
        PlanId("plan-invalid-out");
        operations = [disc],
        bindings = [
            PlanBinding(
                :geometry;
                object_id = geom.object_id,
                revision_id = geom.revision_id,
                content_id = geom.content_id,
            ),
            PlanBinding(:mesh; source = :discretize, object_id = ObjectId(ID_MESH)),
        ],
    )
    graph = ArchiveGraph(
        [geom];
        heads = [_head()],
        revisions = [RevisionRecord(RevisionId(REV_1))],
    )
    run = execute!(graph, plan; head = :main, store = store)
    @test run.status === :completed
    store_payload!(store, ObjectId(ID_MESH), FixtureGeometry("bad", 0))
    @test_throws ArgumentError commit!(graph, run.id; head = :main, store = store)
    @test graph.heads[1].revision_id == RevisionId(REV_1)
    @test find_run(graph, run.id).revision_id === nothing
    @test any(e -> e.kind === :validation_failed, ordered_run_events(graph, run.id))
end

@testset "interrupted commit recovers without publishing a head" begin
    geom, store = _root_geometry()
    disc = OperationSpec(
        Symbol("fixture/discretize");
        name = :discretize,
        inputs = (:geometry,),
        outputs = (:mesh,),
    )
    plan = Plan(
        PlanId("plan-interrupt");
        operations = [disc],
        bindings = [
            PlanBinding(
                :geometry;
                object_id = geom.object_id,
                revision_id = geom.revision_id,
                content_id = geom.content_id,
            ),
            PlanBinding(:mesh; source = :discretize, object_id = ObjectId(ID_MESH)),
        ],
    )
    graph = ArchiveGraph(
        [geom];
        heads = [_head()],
        revisions = [RevisionRecord(RevisionId(REV_1))],
    )
    run = execute!(graph, plan; head = :main, store = store)
    @test_throws ExecutionInterrupted commit!(
        graph, run.id;
        head = :main,
        store = store,
        revision_id = RevisionId(REV_2),
        interrupt_after = :objects,
    )
    @test graph.heads[1].revision_id == RevisionId(REV_1)
    report = recover_writes!(graph)
    @test find_object(graph, ObjectId(ID_MESH), RevisionId(REV_2)) === nothing
    @test find_revision(graph, RevisionId(REV_2)) === nothing
    @test find_run(graph, run.id).revision_id === nothing
    @test any(tx -> tx.phase === :aborted, report.writes)

    rec = commit!(graph, run.id; head = :main, store = store, revision_id = RevisionId(REV_2))
    @test rec.id == RevisionId(REV_2)
    @test graph.heads[1].revision_id == rec.id
end

@testset "head conflict rejects last-writer-wins commit" begin
    geom, store = _root_geometry()
    disc = OperationSpec(
        Symbol("fixture/discretize");
        name = :discretize,
        inputs = (:geometry,),
        outputs = (:mesh,),
    )
    plan = Plan(
        PlanId("plan-conflict");
        operations = [disc],
        bindings = [
            PlanBinding(
                :geometry;
                object_id = geom.object_id,
                revision_id = geom.revision_id,
                content_id = geom.content_id,
            ),
            PlanBinding(:mesh; source = :discretize, object_id = ObjectId(ID_MESH)),
        ],
    )
    graph = ArchiveGraph(
        [geom];
        heads = [_head()],
        revisions = [RevisionRecord(RevisionId(REV_1))],
    )
    run_a = execute!(graph, plan; head = :main, store = store)
    run_b = execute!(
        graph,
        Plan(
            PlanId("plan-conflict-b");
            operations = [disc],
            bindings = plan.bindings,
        );
        head = :main,
        store = store,
    )
    commit!(graph, run_a.id; head = :main, store = store, revision_id = RevisionId(REV_2))
    @test_throws ArgumentError commit!(
        graph, run_b.id;
        head = :main,
        store = store,
        revision_id = RevisionId(REV_3),
    )
    @test graph.heads[1].revision_id == RevisionId(REV_2)
end

@testset "duplicate idempotency key is rejected" begin
    geom, store = _root_geometry()
    disc = OperationSpec(
        Symbol("fixture/discretize");
        name = :discretize,
        inputs = (:geometry,),
        outputs = (:mesh,),
        idempotency_key = "mesh-job-1",
        default_reuse = :forbid,
    )
    plan = Plan(
        PlanId("plan-idem");
        operations = [disc],
        bindings = [
            PlanBinding(
                :geometry;
                object_id = geom.object_id,
                revision_id = geom.revision_id,
                content_id = geom.content_id,
            ),
            PlanBinding(:mesh; source = :discretize, object_id = ObjectId(ID_MESH)),
        ],
    )
    graph = ArchiveGraph(
        [geom];
        heads = [_head()],
        revisions = [RevisionRecord(RevisionId(REV_1))],
    )
    first = execute!(graph, plan; head = :main, store = store)
    @test first.status === :completed
    second = execute!(graph, plan; head = :main, store = store)
    @test second.status === :failed
    @test any(e -> e.kind === :failed, ordered_run_events(graph, second.id))
end

@testset "restart fails closed on checkpoint content mismatch" begin
    geom, store = _root_geometry()
    activity = ActivityRecord(ActivityId("act-1"), RunId("run-rst"), Symbol("fixture/discretize"))
    run = RunRecord(
        RunId("run-rst");
        status = :interrupted,
        activities = [activity],
        staged = [StagedObject(
            ObjectId(ID_MESH);
            namespace = FIX_NS,
            kind = schema_kind(MESH_SCHEMA),
            schema = MESH_SCHEMA,
            content_id = ContentId("mesh-old"),
            activity_id = activity.id,
        )],
        restart = RestartRequirement(;
            checkpoints = [CheckpointRef(
                ObjectId(ID_MESH);
                content_id = ContentId("mesh-live"),
            )],
        ),
    )
    graph = ArchiveGraph(
        [geom];
        heads = [_head()],
        revisions = [RevisionRecord(RevisionId(REV_1))],
        runs = [run],
    )
    @test !isready(readiness(graph, PipelineTarget(:restart; run_id = run.id)))
    @test any(d -> d.code === :incompatible_restart_content || d.code === :missing_restart_checkpoint,
        readiness(graph, PipelineTarget(:restart; run_id = run.id)).diagnostics)
end

@testset "external artifact content identity" begin
    mktemp() do path, io
        write(io, "geometry-bytes-v1")
        close(io)
        cid = external_file_content_id(path)
        disc = OperationSpec(
            Symbol("fixture/discretize");
            name = :discretize,
            inputs = (:geometry,),
            outputs = (:mesh,),
        )
        plan = Plan(
            PlanId("plan-ext");
            operations = [disc],
            bindings = [PlanBinding(
                :geometry;
                artifact = ArtifactRef(:bin; path = path),
                content_id = cid,
                required = true,
            )],
        )
        graph = ArchiveGraph(ArchiveObject[])
        ready = readiness(plan, graph, PipelineTarget(:execute))
        # The file matches, but there is no ArchiveObject; the binding is an
        # external root. Missing payload still fails discretize at execute.
        @test isready(ready) || any(d -> d.code !== :stale_content, ready.diagnostics)
        write(path, "geometry-bytes-v2")
        stale = readiness(plan, graph, PipelineTarget(:execute))
        @test !isready(stale)
        @test any(d -> d.code === :stale_content, stale.diagnostics)
    end
end

@testset "reproduction comparison is domain-neutral" begin
    left = ContentId("sha256:aaa")
    right = ContentId("sha256:aaa")
    other = ContentId("sha256:bbb")
    @test isvalid(compare_reproduction(left, right))
    mismatch = compare_reproduction(left, other)
    @test !isvalid(mismatch)
    @test mismatch.kind === :exact_content
end
