# Derived-artifact and debug provenance (#105 / parent #32).

function _derived_run(revision, activity_op)
    activity = ActivityRecord(ActivityId("act-derived"), RunId("run-derived"), activity_op)
    return RunRecord(
        RunId("run-derived");
        revision_id = revision,
        status = :completed,
        activities = [activity],
    )
end

function _derived_record(
    object,
    role;
    inputs = DerivedInputRef[],
    operation = :postprocess,
    parameters = (;),
    retention = :forensic,
    status = :complete,
    units = "",
    value_shape = (),
    artifact = nothing,
)
    return DerivedArtifactRecord(
        object.object_id,
        object.revision_id,
        role;
        inputs = inputs,
        run_id = RunId("run-derived"),
        activity_id = ActivityId("act-derived"),
        operation = operation,
        parameters = parameters,
        schema = object.schema,
        retention = retention,
        status = status,
        units = units,
        value_shape = value_shape,
        artifact = artifact,
    )
end

@testset "derived products share a payload-free provenance envelope" begin
    r1 = RevisionId(REV_1)
    mesh = _obj(:delone, "mesh", ID_MESH, REV_1; content = "mesh-bytes", uuid = UUID_DELONE)
    plot = _obj(:oodi, "field", ID_FIELD, REV_1; content = "plot-bytes", uuid = UUID_OODI)
    overlay = _obj(:example, "model-state", ID_SECTOR, REV_1; content = "debug-bytes")
    note = _obj(:example, "model-state", ID_MODEL, REV_1; content = "note-bytes")
    run = _derived_run(r1, :postprocess)
    graph = ArchiveGraph(
        [mesh, plot, overlay, note];
        revisions = [RevisionRecord(r1)],
        runs = [run],
    )
    records = [
        _derived_record(
            plot,
            :visualization;
            inputs = [DerivedInputRef(mesh.object_id, r1; content_id = mesh.content_id)],
            retention = :visualization,
            units = "1",
            value_shape = (nothing,),
            artifact = ArtifactRef(:png; path = "preview.png", description = "plot"),
        ),
        _derived_record(
            overlay,
            :debug;
            inputs = [DerivedInputRef(mesh.object_id, r1; content_id = mesh.content_id)],
            retention = :debug,
        ),
        _derived_record(
            note,
            :annotation;
            inputs = [DerivedInputRef(mesh.object_id, r1; content_id = mesh.content_id)],
        ),
    ]
    @test isvalid(validate(records, graph))
    explained = report(records[1])
    @test occursin(":visualization", explained.summary)
    @test explained.metadata.parameters == (;)
    @test explained.metadata.retention === :visualization
    @test explained.artifacts[1].kind === :png
    @test !occursin("plot-bytes", explained.summary)
end

@testset "recompute with different parameters is a new derived record" begin
    r1 = RevisionId(REV_1)
    r2 = RevisionId(REV_2)
    mesh = _obj(:delone, "mesh", ID_MESH, REV_1; content = "mesh-bytes", uuid = UUID_DELONE)
    coarse = _obj(:oodi, "field", ID_FIELD, REV_1; content = "field-coarse", uuid = UUID_OODI)
    fine = _obj(
        :oodi, "field", ID_FIELD, REV_2;
        content = "field-fine", uuid = UUID_OODI,
    )
    activity = ActivityRecord(ActivityId("act-derived"), RunId("run-derived"), :project)
    run = RunRecord(
        RunId("run-derived");
        revision_id = r2,
        status = :completed,
        activities = [activity],
    )
    graph = ArchiveGraph(
        [mesh, coarse, fine];
        revisions = [RevisionRecord(r1), RevisionRecord(r2; parents = [r1])],
        runs = [run],
    )
    input = DerivedInputRef(mesh.object_id, r1; content_id = mesh.content_id)
    first = _derived_record(
        coarse, :derived;
        inputs = [input], operation = :project, parameters = (; bins = 10),
    )
    second = _derived_record(
        fine, :derived;
        inputs = [input], operation = :project, parameters = (; bins = 40),
    )
    @test first.parameters != second.parameters
    @test first.object_id == second.object_id
    @test first.revision_id != second.revision_id
    @test coarse.content_id != fine.content_id
    @test isvalid(validate([first, second], graph))
end

@testset "derived ancestry walks and rejects cycles or dangling inputs" begin
    r1 = RevisionId(REV_1)
    mesh = _obj(:delone, "mesh", ID_MESH, REV_1; content = "mesh-bytes", uuid = UUID_DELONE)
    mid = _obj(:oodi, "field", ID_FIELD, REV_1; content = "mid-bytes", uuid = UUID_OODI)
    top = _obj(:example, "model-state", ID_SECTOR, REV_1; content = "top-bytes")
    run = _derived_run(r1, :postprocess)
    graph = ArchiveGraph(
        [mesh, mid, top];
        revisions = [RevisionRecord(r1)],
        runs = [run],
    )
    base = _derived_record(
        mid, :derived;
        inputs = [DerivedInputRef(mesh.object_id, r1; content_id = mesh.content_id)],
    )
    child = _derived_record(
        top, :derived;
        inputs = [DerivedInputRef(mid.object_id, r1; content_id = mid.content_id)],
    )
    @test [record.object_id for record in derived_ancestry(child, [base, child])] ==
        [mid.object_id]
    cyclic = _derived_record(
        mid, :derived;
        inputs = [DerivedInputRef(top.object_id, r1; content_id = top.content_id)],
    )
    looped = validate([cyclic, child], graph)
    @test !isvalid(looped)
    @test any(d -> d.code === :derived_ancestry_cycle, looped.diagnostics)

    dangling = _derived_record(
        top, :derived;
        inputs = [DerivedInputRef(ObjectId(ID_GEOM), r1)],
    )
    missing = validate([dangling], graph)
    @test !isvalid(missing)
    @test any(d -> d.code === :dangling_derived_input, missing.diagnostics)

    omitted = _derived_record(
        top, :derived;
        inputs = [DerivedInputRef(mesh.object_id, r1)],
    )
    omitted_id = validate([omitted], graph)
    @test !isvalid(omitted_id)
    @test any(d -> d.code === :missing_derived_input_content_id, omitted_id.diagnostics)

    mismatched = _derived_record(
        top, :derived;
        inputs = [DerivedInputRef(mesh.object_id, r1; content_id = ContentId("other-bytes"))],
    )
    wrong = validate([mismatched], graph)
    @test !isvalid(wrong)
    @test any(d -> d.code === :derived_input_content_mismatch, wrong.diagnostics)
end

@testset "failed derived products keep structural envelope validity" begin
    r1 = RevisionId(REV_1)
    mesh = _obj(:delone, "mesh", ID_MESH, REV_1; content = "mesh-bytes", uuid = UUID_DELONE)
    note = _obj(:example, "model-state", ID_MODEL, REV_1; content = "note-bytes")
    run = _derived_run(r1, :postprocess)
    graph = ArchiveGraph(
        [mesh, note];
        revisions = [RevisionRecord(r1)],
        runs = [run],
    )
    failed = DerivedArtifactRecord(
        note.object_id,
        note.revision_id,
        :annotation;
        inputs = [DerivedInputRef(mesh.object_id, r1; content_id = mesh.content_id)],
        run_id = RunId("run-derived"),
        activity_id = ActivityId("act-derived"),
        operation = :postprocess,
        status = :failed,
        diagnostics = [error_diagnostic(:incomplete, "source was incomplete")],
    )
    report = validate([failed], graph)
    @test isvalid(report)
    @test !any(d -> d.code === :incomplete, report.diagnostics)
    @test failed.status === :failed
    @test failed.diagnostics[1].severity === :error
end

@testset "purge distinguishes derived retention classes" begin
    r1 = RevisionId(REV_1)
    mesh = _obj(:delone, "mesh", ID_MESH, REV_1; content = "mesh-bytes", uuid = UUID_DELONE)
    vis = _obj(:oodi, "field", ID_FIELD, REV_1; content = "vis-bytes", uuid = UUID_OODI)
    replaceable = _obj(:example, "model-state", ID_SECTOR, REV_1; content = "tmp-bytes")
    pinned = _obj(:example, "model-state", ID_MODEL, REV_1; content = "keep-bytes")
    run = _derived_run(r1, :postprocess)
    graph = ArchiveGraph(
        [mesh, vis, replaceable, pinned];
        revisions = [RevisionRecord(r1)],
        runs = [run],
    )
    records = [
        _derived_record(mesh, :primary; retention = :forensic),
        _derived_record(vis, :visualization; retention = :visualization),
        _derived_record(replaceable, :debug; retention = :replaceable),
        _derived_record(pinned, :debug; retention = :pinned),
    ]
    @test isvalid(validate(records, graph))
    plan = plan_purge(graph, [RetentionRoot(r1)]; derived = records)
    class_of(id) = only(c.class for c in plan.classifications if c.object_id == id)
    @test class_of(mesh.object_id) === :reachable
    @test class_of(vis.object_id) === :purgeable_visualization
    @test class_of(replaceable.object_id) === :replaceable
    @test class_of(pinned.object_id) === :reachable

    compacted = compact_archive(graph, [RetentionRoot(r1)]; derived = records)
    @test compacted.source_unchanged
    @test compacted.graph !== nothing
    ids = Set(object.object_id for object in compacted.graph.objects)
    @test mesh.object_id in ids
    @test pinned.object_id in ids
    @test vis.object_id ∉ ids
    @test replaceable.object_id ∉ ids
end

@testset "purge keeps required derived ancestry of retained products" begin
    r1 = RevisionId(REV_1)
    mesh = _obj(:delone, "mesh", ID_MESH, REV_1; content = "mesh-bytes", uuid = UUID_DELONE)
    parent = _obj(:oodi, "field", ID_FIELD, REV_1; content = "parent-bytes", uuid = UUID_OODI)
    mid = _obj(:example, "model-state", ID_SECTOR, REV_1; content = "mid-bytes")
    child = _obj(:example, "model-state", ID_MODEL, REV_1; content = "child-bytes")
    sibling = _obj(:example, "model-state", ID_POST, REV_1; content = "sibling-bytes")
    run = _derived_run(r1, :postprocess)
    graph = ArchiveGraph(
        [mesh, parent, mid, child, sibling];
        revisions = [RevisionRecord(r1)],
        runs = [run],
    )
    records = [
        _derived_record(mesh, :primary; retention = :forensic),
        _derived_record(
            parent, :debug;
            inputs = [DerivedInputRef(mesh.object_id, r1; content_id = mesh.content_id)],
            retention = :debug,
        ),
        _derived_record(
            mid, :visualization;
            inputs = [DerivedInputRef(parent.object_id, r1; content_id = parent.content_id)],
            retention = :visualization,
        ),
        _derived_record(
            child, :derived;
            inputs = [DerivedInputRef(mid.object_id, r1; content_id = mid.content_id)],
            retention = :pinned,
        ),
        _derived_record(
            sibling, :visualization;
            inputs = [DerivedInputRef(mesh.object_id, r1; content_id = mesh.content_id)],
            retention = :replaceable,
        ),
    ]
    @test isvalid(validate(records, graph))
    plan = plan_purge(graph, [RetentionRoot(r1)]; derived = records)
    class_of(id) = only(c.class for c in plan.classifications if c.object_id == id)
    @test class_of(mesh.object_id) === :reachable
    @test class_of(parent.object_id) === :reachable
    @test class_of(mid.object_id) === :reachable
    @test class_of(child.object_id) === :reachable
    @test class_of(sibling.object_id) === :replaceable
    @test isvalid(validate(plan))

    compacted = compact_archive(graph, [RetentionRoot(r1)]; derived = records)
    @test compacted.source_unchanged
    @test compacted.graph !== nothing
    ids = Set(object.object_id for object in compacted.graph.objects)
    @test mesh.object_id in ids
    @test parent.object_id in ids
    @test mid.object_id in ids
    @test child.object_id in ids
    @test sibling.object_id ∉ ids
end

@testset "purge fails closed when a retained derived input is omitted" begin
    r1 = RevisionId(REV_1)
    parent = _obj(:oodi, "field", ID_FIELD, REV_1; content = "parent-bytes", uuid = UUID_OODI)
    child = _obj(:example, "model-state", ID_MODEL, REV_1; content = "child-bytes")
    run = _derived_run(r1, :postprocess)
    graph = ArchiveGraph(
        [parent, child];
        revisions = [RevisionRecord(r1)],
        runs = [run],
    )
    records = [
        _derived_record(parent, :visualization; retention = :visualization),
        _derived_record(
            child, :derived;
            inputs = [DerivedInputRef(parent.object_id, r1; content_id = parent.content_id)],
            retention = :pinned,
        ),
    ]
    @test isvalid(validate(records, graph))
    root = RetentionRoot(child.object_id, r1)
    plan = plan_purge(graph, [root]; derived = records)
    @test !isvalid(validate(plan))
    @test any(d -> d.code === :derived_retention_input_omitted, plan.diagnostics)
    compacted = compact_archive(graph, [root]; derived = records)
    @test compacted.source_unchanged
    @test compacted.graph === nothing
    @test any(d -> d.code === :derived_retention_input_omitted, compacted.report.diagnostics)
end
