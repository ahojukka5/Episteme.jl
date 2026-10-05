# One Delone operation recorded by Episteme's lifecycle.
# Delone owns the triangulation. This file only binds apply_operation.
# Episteme's Project.toml does not depend on Delone.

import Pkg
import TOML
Pkg.instantiate(; io = devnull)

using Test
using Delone
using Episteme

import Episteme: apply_operation

const DELONE_SHA = "cdd17d11940bd0773408725d51d10009ce1be3a9"
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

const SQUARE = [
    0.0 1.0 1.0 0.0
    0.0 0.0 1.0 1.0
]
const COLLINEAR = [
    0.0 1.0 2.0 3.0
    0.0 0.0 0.0 0.0
]

function apply_operation(::Val{DELONE_KIND}, spec::OperationSpec, inputs; plan, kwargs...)
    points = inputs[:points].payload
    push!(SEEN_INPUTS, points)
    snapshot = try
        delaunay_triangulation(points)
    catch err
        err isa ArgumentError || rethrow()
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
            content_id = ContentId("sha256:" * String(to_namedtuple(snapshot).content_digest)),
            references = refs,
        )],
    )
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

function _plan(source, mesh_id)
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

function _prepare(points, object_value, revision_value)
    content_id = canonical_content_id(points)
    source = _source_object(ObjectId(object_value), RevisionId(revision_value), content_id)
    store = WorkingStore()
    store_payload!(store, source.object_id, points; revision_id = source.revision_id)
    mesh_id = ObjectId(object_value * "-mesh")
    return source, store, _plan(source, mesh_id), _graph(source), mesh_id
end

function _direct_proof()
    project = joinpath(@__DIR__, "direct")
    script = joinpath(project, "runtests.jl")
    exe = joinpath(Sys.BINDIR, Base.julia_exename())
    cmd = addenv(
        `$exe --startup-file=no -t 4 --project=$project $script`,
        "JULIA_PKG_PRECOMPILE_AUTO" => "0",
    )
    buffer = IOBuffer()
    ok = success(pipeline(cmd; stdout = buffer, stderr = buffer))
    text = String(take!(buffer))
    print(text)
    return ok, text
end

function _owner_source_has_no_lifecycle()
    method = which(delaunay_triangulation, (Matrix{Float64},))
    method.module === Delone.Algorithms || return false
    source = read(String(method.file), String)
    for needle in ("execute!", "commit!", "WorkingStore", "ArchiveGraph", "apply_operation")
        occursin(needle, source) && return false
    end
    return true
end

function main()
    empty!(SEEN_INPUTS)
    empty!(PRODUCED)
    direct_ok, direct_text = _direct_proof()
    direct_match = match(r"^EPISTEME_DIRECT_DIGEST=([0-9a-f]{64})$"m, direct_text)

    ts = @testset "Delone delaunay scientific lifecycle" begin
        @testset "operation runs with no Episteme and no Oodi orchestration" begin
            @test direct_ok
            @test direct_match !== nothing
            @test !isdefined(Episteme, :delaunay_triangulation)
            @test _owner_source_has_no_lifecycle()
            @test parentmodule(delaunay_triangulation) === Delone.Algorithms
        end

        @testset "source identity survives and Delone performs the operation" begin
            direct_digest = direct_match === nothing ? "" : direct_match.captures[1]
            points = SQUARE
            source, store, plan, graph, mesh_id = _prepare(points, "delone-square", "rev-points")
            @test source.content_id == canonical_content_id(points)
            @test !startswith(String(DELONE_KIND), "episteme/")
            @test isready(readiness(
                plan, graph, PipelineTarget(:execute; head = :main, store = store),
            ))
            run = execute!(
                graph, plan;
                head = :main,
                store = store,
                run_id = RunId("run-delaunay"),
            )
            @test run.status === :completed
            @test only(SEEN_INPUTS) === points
            @test fetch_payload(store, source.object_id; revision_id = source.revision_id) === points
            produced = only(PRODUCED)
            @test produced isa MeshLevelSnapshot
            @test String(to_namedtuple(produced).content_digest) == direct_digest
            @test Delone.Algorithms.exact_delaunay_invariants_2d(produced).triangle_count == 2
            @test only(run.activities).operation === DELONE_KIND
            @test only(run.activities).reuse === :computed
            @test only(run.staged).content_id ==
                ContentId("sha256:" * direct_digest)
            @test only(run.staged).object_id == mesh_id
            kept = find_object(graph, source.object_id, source.revision_id)
            @test kept.content_id == source.content_id
            @test kept.revision_id == source.revision_id
        end

        @testset "Episteme records intent, activity, and the committed revision" begin
            direct_digest = direct_match === nothing ? "" : direct_match.captures[1]
            points = SQUARE
            source, store, plan, graph, mesh_id = _prepare(points, "delone-commit", "rev-commit-points")
            mesh_rev = RevisionId("rev-commit-mesh")
            run = execute!(
                graph, plan;
                head = :main,
                store = store,
                run_id = RunId("run-commit"),
            )
            @test run.plan_id == plan.id
            @test run.revision_id === nothing
            planned = only(event for event in ordered_run_events(graph, run.id) if event.kind === :planned)
            @test planned.payload.plan_id == plan.id.value
            @test any(event -> event.kind === :started, ordered_run_events(graph, run.id))
            @test any(event -> event.kind === :staged, ordered_run_events(graph, run.id))
            @test !any(event -> event.kind === :committed, ordered_run_events(graph, run.id))
            record = commit!(
                graph, run.id;
                head = :main,
                store = store,
                revision_id = mesh_rev,
            )
            mesh = find_object(graph, mesh_id, mesh_rev)
            committed = find_run(graph, run.id)
            @test record.id == mesh_rev
            @test record.run_id == run.id
            @test record.plan_id == plan.id
            @test record.parents == [source.revision_id]
            @test graph.heads[1].revision_id == mesh_rev
            @test committed.revision_id == mesh_rev
            @test mesh.content_id == ContentId("sha256:" * direct_digest)
            @test mesh.kind === Symbol("delone/mesh-level-snapshot")
            @test fetch_payload(store, mesh_id; revision_id = mesh_rev) === PRODUCED[end]
            @test fetch_payload(store, source.object_id; revision_id = source.revision_id) === points
            @test find_object(graph, source.object_id, source.revision_id).content_id ==
                source.content_id
            @test producing_activity(graph, mesh).operation === DELONE_KIND
            @test producing_run(graph, mesh).id == run.id
            @test any(
                ref -> ref.target.object_id == source.object_id &&
                    ref.target.revision_id == source.revision_id,
                used_inputs(graph, mesh),
            )
            @test any(event -> event.kind === :committed, ordered_run_events(graph, run.id))
            @test !isready(readiness(graph, PipelineTarget(:commit; run_id = run.id)))
            @test any(
                diagnostic -> diagnostic.code === :run_already_committed,
                readiness(graph, PipelineTarget(:commit; run_id = run.id)).diagnostics,
            )
        end

        @testset "uncommitted activity stays distinct from a revision" begin
            points = SQUARE
            source, store, plan, graph, mesh_id = _prepare(
                points, "delone-uncommitted", "rev-uncommitted-points",
            )
            run = execute!(
                graph, plan;
                head = :main,
                store = store,
                run_id = RunId("run-uncommitted"),
            )
            @test run.status === :completed
            @test run.revision_id === nothing
            @test length(run.staged) == 1
            @test graph.heads[1].revision_id == source.revision_id
            @test length(graph.revisions) == 1
            @test all(object -> object.object_id != mesh_id, graph.objects)
            @test find_revision(graph, RevisionId("rev-uncommitted-mesh")) === nothing
            @test !any(event -> event.kind === :committed, ordered_run_events(graph, run.id))
            @test isready(readiness(graph, PipelineTarget(:commit; run_id = run.id)))
            @test SEEN_INPUTS[end] === points
            @test fetch_payload(store, source.object_id; revision_id = source.revision_id) === points
        end

        @testset "failed activity stays distinct from committed history" begin
            before = length(PRODUCED)
            collinear = COLLINEAR
            owner_error = try
                delaunay_triangulation(collinear)
                ""
            catch err
                sprint(showerror, err)
            end
            @test occursin("collinear", owner_error)
            source, store, plan, graph, mesh_id = _prepare(
                collinear, "delone-collinear", "rev-collinear",
            )
            revisions_before = length(graph.revisions)
            failed = execute!(
                graph, plan;
                head = :main,
                store = store,
                run_id = RunId("run-collinear"),
            )
            @test failed.status === :failed
            @test failed.revision_id === nothing
            @test isempty(failed.staged)
            @test length(PRODUCED) == before
            @test SEEN_INPUTS[end] === collinear
            @test graph.heads[1].revision_id == source.revision_id
            @test length(graph.revisions) == revisions_before
            @test all(object -> object.object_id != mesh_id, graph.objects)
            @test !isready(readiness(graph, PipelineTarget(:commit; run_id = failed.id)))
            @test any(
                diagnostic -> diagnostic.code === :run_not_completed,
                readiness(graph, PipelineTarget(:commit; run_id = failed.id)).diagnostics,
            )
            @test_throws ArgumentError commit!(
                graph, failed.id;
                head = :main,
                store = store,
                revision_id = RevisionId("rev-should-not-exist"),
            )
            @test graph.heads[1].revision_id == source.revision_id
            @test length(graph.revisions) == revisions_before
            failed_event = only(
                event for event in ordered_run_events(graph, failed.id) if event.kind === :failed
            )
            @test failed_event.message == owner_error
            @test !any(event -> event.kind === :committed, ordered_run_events(graph, failed.id))
            @test find_object(graph, source.object_id, source.revision_id).content_id ==
                canonical_content_id(collinear)
        end

        @testset "pinned owner is the recorded Delone revision" begin
            project = TOML.parsefile(joinpath(@__DIR__, "Project.toml"))
            direct = TOML.parsefile(joinpath(@__DIR__, "direct", "Project.toml"))
            @test project["sources"]["Delone"]["rev"] == DELONE_SHA
            @test direct["sources"]["Delone"]["rev"] == DELONE_SHA
            @test length(project["sources"]["Delone"]["rev"]) == 40
            @test direct["sources"]["Episteme"]["rev"] ==
                "f1cb1b7fe6a7f78b96098bbd8a24b0797c6bc640"
            @test !occursin("using Episteme", read(joinpath(@__DIR__, "direct", "runtests.jl"), String))
            @test !occursin("import Episteme", read(joinpath(@__DIR__, "direct", "runtests.jl"), String))
            @test !haskey(direct["deps"], "Oodi")
            episteme = TOML.parsefile(joinpath(dirname(dirname(@__DIR__)), "Project.toml"))
            @test !haskey(get(episteme, "deps", Dict()), "Delone")
            @test !haskey(get(episteme, "extras", Dict()), "Delone")
            @test !haskey(get(episteme, "weakdeps", Dict()), "Delone")
        end
    end
    return ts.anynonpass ? 1 : 0
end

exit(main())
