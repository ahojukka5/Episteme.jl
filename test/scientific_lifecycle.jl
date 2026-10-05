# Delone owns the triangulation. This script only binds Episteme's lifecycle
# around that public function. Episteme's project does not depend on Delone;
# test/scientific_lifecycle_runner.jl starts this in a temporary environment.

import Pkg
Pkg.instantiate(; io = devnull)

using Test
using Delone
using Episteme

import Episteme: apply_operation

const DELONE_UUID = "0a3734f8-1dfd-4ffb-90f2-cbaa38dcac37"
const DELONE_KIND = Symbol("delone/delaunay-triangulation")
const DELONE_NS = ArchiveNamespace(
    :delone;
    package_uuid = DELONE_UUID,
    display_name = "Delone.jl",
)
const POINT_SCHEMA = SchemaRef(:delone, "point-cloud", "1")
const MESH_SCHEMA = SchemaRef(:delone, "mesh-level-snapshot", "1")
const SEEN_INPUTS = Any[]
const PRODUCED = Any[]

function _mesh_content_id(snapshot)
    digest = String(to_namedtuple(snapshot).content_digest)
    return ContentId("delone-mesh-level-v1:" * digest)
end

function apply_operation(::Val{DELONE_KIND}, spec::OperationSpec, inputs; plan, kwargs...)
    points = inputs[:points].payload
    push!(SEEN_INPUTS, points)
    snapshot = try
        delaunay_triangulation(points)
    catch err
        return OperationOutcome(;
            status = :failed,
            message = sprint(showerror, err),
            diagnostics = [error_diagnostic(
                :domain_operation_failed,
                "Delone delaunay_triangulation rejected the point cloud",
                owner = :delone,
            )],
        )
    end
    push!(PRODUCED, snapshot)
    point_object = inputs[:points].object
    refs = ArchiveReference[]
    if point_object !== nothing
        push!(refs, ArchiveReference(
            :points,
            point_object.object_id;
            revision_id = point_object.revision_id,
        ))
    end
    return OperationOutcome(;
        outputs = [staged_result(
            plan_output_id(plan, spec, :mesh),
            snapshot;
            namespace = DELONE_NS,
            kind = schema_kind(MESH_SCHEMA),
            schema = MESH_SCHEMA,
            content_id = _mesh_content_id(snapshot),
            references = refs,
        )],
    )
end

function _square_points()
    return [
        0.0  1.0  1.0  0.0  0.5
        0.0  0.0  1.0  1.0  0.5
    ]
end

function _collinear_points()
    return [
        0.0  1.0  2.0
        0.0  0.0  0.0
    ]
end

function _source_object(object_id, revision_id, content_id)
    return ArchiveObject(
        object_id,
        revision_id;
        content_id = content_id,
        namespace = DELONE_NS,
        kind = schema_kind(POINT_SCHEMA),
        schema = POINT_SCHEMA,
    )
end

function _triangulate_plan(source, mesh_id)
    spec = OperationSpec(
        DELONE_KIND;
        name = :triangulate,
        inputs = (:points,),
        outputs = (:mesh,),
        input_ports = [OperationPort(
            :points;
            schema = POINT_SCHEMA,
            kind = schema_kind(POINT_SCHEMA),
        )],
        output_ports = [OperationPort(
            :mesh;
            schema = MESH_SCHEMA,
            kind = schema_kind(MESH_SCHEMA),
        )],
    )
    return Plan(
        PlanId("delone-delaunay-" * source.object_id.value);
        operations = [spec],
        bindings = [
            PlanBinding(
                :points;
                object_id = source.object_id,
                revision_id = source.revision_id,
                content_id = source.content_id,
                schema = POINT_SCHEMA,
                kind = schema_kind(POINT_SCHEMA),
            ),
            PlanBinding(
                :mesh;
                source = :triangulate,
                object_id = mesh_id,
                schema = MESH_SCHEMA,
                kind = schema_kind(MESH_SCHEMA),
            ),
        ],
    )
end

function _graph(source)
    revision = source.revision_id
    return ArchiveGraph(
        [source];
        heads = [WorkflowHead(WorkflowHeadId("head-main"), :main, revision)],
        revisions = [RevisionRecord(revision)],
    )
end

function _loaded_package_names()
    return Set(id.name for id in keys(Base.loaded_modules))
end

function main()
    empty!(SEEN_INPUTS)
    empty!(PRODUCED)
    points = _square_points()
    points_content = canonical_content_id(points)
    points_id = ObjectId("delone-square-with-center")
    mesh_id = ObjectId("delone-square-with-center-mesh")
    points_rev = RevisionId("rev-points")
    mesh_rev = RevisionId("rev-mesh")
    source = _source_object(points_id, points_rev, points_content)
    store = WorkingStore()
    store_payload!(store, points_id, points; revision_id = points_rev)
    plan = _triangulate_plan(source, mesh_id)
    graph = _graph(source)

    ts = @testset "Delone delaunay scientific lifecycle" begin
        @testset "domain operation without Oodi or Maudslay" begin
            loaded = _loaded_package_names()
            @test "Oodi" ∉ loaded
            @test "Maudslay" ∉ loaded
            @test "Irons" ∉ loaded
            @test !isdefined(Episteme, :delaunay_triangulation)
            @test parentmodule(delaunay_triangulation) === Delone.Algorithms
            direct = delaunay_triangulation(points)
            @test isvalid(validate(direct))
            @test size(direct.volume_connectivity) == (3, 4)
            @test Delone.Algorithms.exact_delaunay_invariants_2d(direct).valid
            @test points == _square_points()
        end

        @testset "committed lifecycle keeps the source and Delone's result" begin
            @test schema_kind(MESH_SCHEMA) === Symbol("delone/mesh-level-snapshot")
            @test !startswith(String(DELONE_KIND), "episteme/")
            @test isready(readiness(
                plan, graph, PipelineTarget(:execute; head = :main, store = store),
            ))
            run = execute!(graph, plan; head = :main, store = store, run_id = RunId("run-delaunay"))
            @test run.status === :completed
            @test run.revision_id === nothing
            @test run.plan_id == plan.id
            @test graph.heads[1].revision_id == points_rev
            @test find_object(graph, mesh_id, mesh_rev) === nothing
            @test length(graph.revisions) == 1
            @test only(run.activities).operation === DELONE_KIND
            @test SEEN_INPUTS[1] === points
            @test fetch_payload(store, points_id; revision_id = points_rev) === points
            @test fetch_payload(store, mesh_id) === only(PRODUCED)
            staged = only(run.staged)
            @test staged.content_id == _mesh_content_id(only(PRODUCED))
            @test !any(event -> event.kind === :committed, ordered_run_events(graph, run.id))
            planned = only(event for event in ordered_run_events(graph, run.id) if event.kind === :planned)
            @test planned.payload.plan_id == plan.id.value
            @test any(event -> event.kind === :started, ordered_run_events(graph, run.id))
            @test any(event -> event.kind === :staged, ordered_run_events(graph, run.id))

            direct = delaunay_triangulation(points)
            @test to_namedtuple(direct).content_digest == to_namedtuple(only(PRODUCED)).content_digest
            @test direct !== only(PRODUCED)
            @test Delone.Algorithms.exact_delaunay_invariants_2d(only(PRODUCED)).triangle_count == 4

            @test isready(readiness(graph, PipelineTarget(:commit; run_id = run.id)))
            record = commit!(
                graph, run.id;
                head = :main,
                store = store,
                revision_id = mesh_rev,
            )
            committed = find_run(graph, run.id)
            mesh = find_object(graph, mesh_id, mesh_rev)
            @test record.id == mesh_rev
            @test graph.heads[1].revision_id == mesh_rev
            @test committed.revision_id == mesh_rev
            @test committed.status === :completed
            @test mesh !== nothing
            @test mesh.content_id == _mesh_content_id(only(PRODUCED))
            @test mesh.kind === Symbol("delone/mesh-level-snapshot")
            @test fetch_payload(store, mesh_id; revision_id = mesh_rev) === only(PRODUCED)
            @test fetch_payload(store, points_id; revision_id = points_rev) === points
            kept = find_object(graph, points_id, points_rev)
            @test kept.content_id == points_content
            @test kept.revision_id == points_rev
            @test producing_activity(graph, mesh).operation === DELONE_KIND
            @test producing_run(graph, mesh).id == run.id
            used = used_inputs(graph, mesh)
            @test any(ref -> ref.target.object_id == points_id && ref.target.revision_id == points_rev, used)
            @test any(event -> event.kind === :committed, ordered_run_events(graph, run.id))
            @test points == _square_points()
        end

        @testset "failed triangulation is not a commit" begin
            collinear = _collinear_points()
            direct_error = try
                delaunay_triangulation(collinear)
                ""
            catch err
                sprint(showerror, err)
            end
            @test occursin("collinear", direct_error)
            bad_content = canonical_content_id(collinear)
            bad_id = ObjectId("delone-collinear")
            bad_rev = RevisionId("rev-collinear")
            bad_source = _source_object(bad_id, bad_rev, bad_content)
            bad_store = WorkingStore()
            store_payload!(bad_store, bad_id, collinear; revision_id = bad_rev)
            bad_plan = _triangulate_plan(bad_source, ObjectId("delone-collinear-mesh"))
            bad_graph = _graph(bad_source)
            revisions_before = length(bad_graph.revisions)
            failed = execute!(
                bad_graph, bad_plan;
                head = :main,
                store = bad_store,
                run_id = RunId("run-collinear"),
            )
            @test failed.status === :failed
            @test failed.revision_id === nothing
            @test isempty(failed.staged)
            @test bad_graph.heads[1].revision_id == bad_rev
            @test length(bad_graph.revisions) == revisions_before
            @test find_object(bad_graph, ObjectId("delone-collinear-mesh"), bad_rev) === nothing
            @test !isready(readiness(bad_graph, PipelineTarget(:commit; run_id = failed.id)))
            @test_throws ArgumentError commit!(
                bad_graph, failed.id;
                head = :main,
                store = bad_store,
                revision_id = RevisionId("rev-should-not-exist"),
            )
            @test bad_graph.heads[1].revision_id == bad_rev
            @test length(bad_graph.revisions) == revisions_before
            failed_event = only(event for event in ordered_run_events(bad_graph, failed.id) if event.kind === :failed)
            @test failed_event.message == direct_error
            @test !any(event -> event.kind === :committed, ordered_run_events(bad_graph, failed.id))
            @test SEEN_INPUTS[end] === collinear
            @test fetch_payload(bad_store, bad_id; revision_id = bad_rev) === collinear
            @test find_object(bad_graph, bad_id, bad_rev).content_id == bad_content
            @test length(PRODUCED) == 1
        end
    end
    return ts.anynonpass ? 1 : 0
end

exit(main())
