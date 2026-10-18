# An end-to-end test of Episteme's in-memory scientific lifecycle using only a
# deterministic toy experiment. The synthetic calibration belongs exclusively
# to test code; Episteme never owns or interprets its "scientific" operation.
include("synthetic_experiment.jl")

import Episteme: apply_operation

const MOCK_EXPERIMENT_NS = ArchiveNamespace(
    :synthetic; display_name = "Synthetic experiment",
)
const MOCK_OBSERVATIONS_SCHEMA = SchemaRef(:synthetic, "observations", "1")
const MOCK_FIT_SCHEMA = SchemaRef(:synthetic, "linear-calibration", "1")
const MOCK_EXPERIMENT_KIND = Symbol("synthetic/fit-linear-calibration")
const MOCK_SEEN_INPUTS = Any[]
const MOCK_PRODUCED = Any[]

# The domain operation is deliberately defined in the test and not in src/.
function apply_operation(
    ::Val{MOCK_EXPERIMENT_KIND},
    spec::OperationSpec,
    inputs;
    plan,
    kwargs...,
)
    observations = inputs[:observations].payload
    push!(MOCK_SEEN_INPUTS, observations)
    fit = try
        SyntheticCalibration.calibrate(observations)
    catch err
        err isa ArgumentError || rethrow()
        return OperationOutcome(;
            status = :failed,
            message = sprint(showerror, err),
            diagnostics = [error_diagnostic(
                :invalid_synthetic_observations,
                "The mock calibration rejected its input"; owner = :synthetic,
            )],
        )
    end

    push!(MOCK_PRODUCED, fit)
    input_object = inputs[:observations].object
    references = ArchiveReference[]
    if input_object !== nothing
        push!(references, ArchiveReference(
            :observations,
            input_object.object_id;
            revision_id = input_object.revision_id,
        ))
    end

    return OperationOutcome(;
        outputs = [staged_result(
            plan_output_id(plan, spec, :fit),
            fit;
            namespace = MOCK_EXPERIMENT_NS,
            kind = schema_kind(MOCK_FIT_SCHEMA),
            schema = MOCK_FIT_SCHEMA,
            content_id = canonical_content_id(fit),
            references = references,
        )],
    )
end

function _mock_source(object_id, revision_id, content_id)
    return ArchiveObject(
        object_id,
        revision_id;
        content_id = content_id,
        namespace = MOCK_EXPERIMENT_NS,
        kind = schema_kind(MOCK_OBSERVATIONS_SCHEMA),
        schema = MOCK_OBSERVATIONS_SCHEMA,
    )
end

function _mock_plan(source, fit_id)
    spec = OperationSpec(
        MOCK_EXPERIMENT_KIND;
        name = :calibrate,
        inputs = (:observations,),
        outputs = (:fit,),
        input_ports = [OperationPort(
            :observations;
            schema = MOCK_OBSERVATIONS_SCHEMA,
            kind = schema_kind(MOCK_OBSERVATIONS_SCHEMA),
        )],
        output_ports = [OperationPort(
            :fit;
            schema = MOCK_FIT_SCHEMA,
            kind = schema_kind(MOCK_FIT_SCHEMA),
        )],
    )
    return Plan(
        PlanId("synthetic-calibration-" * source.object_id.value);
        operations = [spec],
        bindings = [
            PlanBinding(
                :observations;
                object_id = source.object_id,
                revision_id = source.revision_id,
                content_id = source.content_id,
                schema = MOCK_OBSERVATIONS_SCHEMA,
                kind = schema_kind(MOCK_OBSERVATIONS_SCHEMA),
            ),
            PlanBinding(
                :fit;
                source = :calibrate,
                object_id = fit_id,
                schema = MOCK_FIT_SCHEMA,
                kind = schema_kind(MOCK_FIT_SCHEMA),
            ),
        ],
    )
end

function _mock_graph(source)
    revision = source.revision_id
    return ArchiveGraph(
        [source];
        heads = [WorkflowHead(WorkflowHeadId("head-main"), :main, revision)],
        revisions = [RevisionRecord(revision)],
    )
end

@testset "dependency-free synthetic scientific lifecycle" begin
    empty!(MOCK_SEEN_INPUTS)
    empty!(MOCK_PRODUCED)

    @testset "the synthetic experiment is independent and deterministic" begin
        observations = SyntheticCalibration.observations()
        fit = SyntheticCalibration.calibrate(observations)
        @test fit.slope == 2.0
        @test fit.intercept == 1.0
        @test fit.max_residual == 0.0
        @test fit.npoints == 5
        @test fit == SyntheticCalibration.calibrate(copy(observations))
        @test canonical_content_id(fit) ==
            canonical_content_id(SyntheticCalibration.calibrate(copy(observations)))
        @test canonical_content_id(fit) !=
            canonical_content_id((; slope = fit.slope, intercept = 2.0,
                max_residual = fit.max_residual, npoints = fit.npoints))
        @test parentmodule(SyntheticCalibration.calibrate) === SyntheticCalibration
        @test !isdefined(Episteme, :calibrate)
        @test !startswith(String(MOCK_EXPERIMENT_KIND), "episteme/")
        @test_throws ArgumentError SyntheticCalibration.calibrate(
            SyntheticCalibration.degenerate_observations(),
        )
        @test_throws ArgumentError SyntheticCalibration.calibrate(fill(NaN, 2, 3))
    end

    @testset "execute, stage, provenance, and commit" begin
        observations = SyntheticCalibration.observations()
        observations_id = ObjectId("synthetic-observations")
        observations_rev = RevisionId("rev-observations")
        fit_id = ObjectId("synthetic-calibration-fit")
        fit_rev = RevisionId("rev-calibration-fit")
        observations_content = canonical_content_id(observations)
        source = _mock_source(observations_id, observations_rev, observations_content)
        store = WorkingStore()
        store_payload!(
            store, observations_id, observations; revision_id = observations_rev,
        )
        plan = _mock_plan(source, fit_id)
        graph = _mock_graph(source)
        direct_fit = SyntheticCalibration.calibrate(observations)

        @test isready(readiness(
            plan, graph, PipelineTarget(:execute; head = :main, store = store),
        ))
        run = execute!(
            graph, plan;
            head = :main, store = store, run_id = RunId("run-synthetic-fit"),
        )
        @test run.status === :completed
        @test run.revision_id === nothing
        @test run.plan_id == plan.id
        @test only(run.activities).operation === MOCK_EXPERIMENT_KIND
        @test only(MOCK_SEEN_INPUTS) === observations
        @test only(MOCK_PRODUCED) == direct_fit
        @test only(run.staged).content_id == canonical_content_id(direct_fit)
        @test only(run.staged).object_id == fit_id
        @test fetch_payload(store, fit_id) === only(MOCK_PRODUCED)
        @test fetch_payload(
            store, observations_id; revision_id = observations_rev,
        ) === observations

        # Nothing is committed until commit! moves the history head.
        @test graph.heads[1].revision_id == observations_rev
        @test length(graph.revisions) == 1
        @test find_object(graph, fit_id, fit_rev) === nothing
        @test !any(
            event -> event.kind === :committed,
            ordered_run_events(graph, run.id),
        )
        events = ordered_run_events(graph, run.id)
        planned = only(event for event in events if event.kind === :planned)
        @test planned.payload.plan_id == plan.id.value
        @test any(event -> event.kind === :started, events)
        @test any(event -> event.kind === :staged, events)

        @test isready(readiness(
            graph, PipelineTarget(:commit; run_id = run.id),
        ))
        record = commit!(
            graph, run.id;
            head = :main, store = store, revision_id = fit_rev,
        )
        committed = find_run(graph, run.id)
        output = find_object(graph, fit_id, fit_rev)
        @test record.id == fit_rev
        @test record.run_id == run.id
        @test record.plan_id == plan.id
        @test record.parents == [observations_rev]
        @test graph.heads[1].revision_id == fit_rev
        @test committed.revision_id == fit_rev
        @test committed.status === :completed
        @test output !== nothing
        @test output.content_id == canonical_content_id(direct_fit)
        @test output.kind === Symbol("synthetic/linear-calibration")
        @test fetch_payload(store, fit_id; revision_id = fit_rev) ===
            only(MOCK_PRODUCED)
        @test fetch_payload(
            store, observations_id; revision_id = observations_rev,
        ) === observations
        kept = find_object(graph, observations_id, observations_rev)
        @test kept.content_id == observations_content
        @test kept.revision_id == observations_rev
        @test producing_activity(graph, output).operation === MOCK_EXPERIMENT_KIND
        @test producing_run(graph, output).id == run.id
        @test any(
            ref -> ref.target.object_id == observations_id &&
                ref.target.revision_id == observations_rev,
            used_inputs(graph, output),
        )
        @test any(
            event -> event.kind === :committed,
            ordered_run_events(graph, run.id),
        )
        @test !isready(readiness(
            graph, PipelineTarget(:commit; run_id = run.id),
        ))
        @test observations == SyntheticCalibration.observations()
    end

    @testset "failed mock experiment cannot enter committed history" begin
        observations = SyntheticCalibration.degenerate_observations()
        expected_error = try
            SyntheticCalibration.calibrate(observations)
            ""
        catch err
            sprint(showerror, err)
        end
        @test occursin("distinct input values", expected_error)

        observations_id = ObjectId("synthetic-degenerate-observations")
        observations_rev = RevisionId("rev-degenerate")
        fit_id = ObjectId("synthetic-degenerate-fit")
        observations_content = canonical_content_id(observations)
        source = _mock_source(
            observations_id, observations_rev, observations_content,
        )
        store = WorkingStore()
        store_payload!(
            store, observations_id, observations; revision_id = observations_rev,
        )
        plan = _mock_plan(source, fit_id)
        graph = _mock_graph(source)
        before = length(MOCK_PRODUCED)

        failed = execute!(
            graph, plan;
            head = :main, store = store, run_id = RunId("run-degenerate"),
        )
        @test failed.status === :failed
        @test failed.revision_id === nothing
        @test isempty(failed.staged)
        @test graph.heads[1].revision_id == observations_rev
        @test length(graph.revisions) == 1
        @test find_object(graph, fit_id, observations_rev) === nothing
        @test !isready(readiness(
            graph, PipelineTarget(:commit; run_id = failed.id),
        ))
        @test_throws ArgumentError commit!(
            graph, failed.id;
            head = :main, store = store, revision_id = RevisionId("should-not-commit"),
        )
        @test graph.heads[1].revision_id == observations_rev
        @test length(graph.revisions) == 1
        failed_event = only(
            event for event in ordered_run_events(graph, failed.id)
            if event.kind === :failed
        )
        @test failed_event.message == expected_error
        @test !any(
            event -> event.kind === :committed,
            ordered_run_events(graph, failed.id),
        )
        @test MOCK_SEEN_INPUTS[end] === observations
        @test length(MOCK_PRODUCED) == before
        @test fetch_payload(
            store, observations_id; revision_id = observations_rev,
        ) === observations
        @test find_object(
            graph, observations_id, observations_rev,
        ).content_id == observations_content
    end
end
