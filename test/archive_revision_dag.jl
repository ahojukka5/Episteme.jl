@testset "revision parent DAG and ancestry" begin
    r0 = RevisionId(REV_1)
    r1 = RevisionId(REV_2)
    r2 = RevisionId(REV_3)
    r3 = RevisionId(REV_4)
    rec0 = RevisionRecord(r0)
    rec1 = RevisionRecord(r1; parents = [r0])
    rec2 = RevisionRecord(r2; parents = [r0])
    rec3 = RevisionRecord(r3; parents = [r1, r2])
    obj0 = _obj(:example, "model-state", ID_SECTOR, REV_1; content = "hash-x")
    obj1 = _obj(:example, "model-state", ID_SECTOR, REV_2; content = "hash-x")
    obj2 = _obj(:example, "model-state", ID_MESH, REV_3; content = "hash-y")
    obj3 = _obj(:example, "model-state", ID_SECTOR, REV_4; content = "hash-x")
    failed = RunRecord(RunId("run-failed"); status = :failed)
    graph = ArchiveGraph(
        [obj0, obj1, obj2, obj3];
        heads = [
            WorkflowHead(WorkflowHeadId("head-main"), :main, r1),
            WorkflowHead(WorkflowHeadId("head-exp"), :experiment, r2),
        ],
        revisions = [rec0, rec1, rec2, rec3],
        runs = [failed],
    )
    @test isvalid(validate(graph))
    @test failed.revision_id === nothing
    @test find_objects(graph, r0) == [obj0]
    @test find_objects(graph, r1) == [obj1]
    @test obj0.object_id == obj1.object_id == obj3.object_id
    @test obj0.content_id == obj1.content_id == obj3.content_id
    @test obj0.revision_id != obj1.revision_id
    @test obj0 !== obj1
    @test obj1 !== obj3

    @test revision_parents(graph, r0) == RevisionRecord[]
    @test [p.id for p in revision_parents(graph, r1)] == [r0]
    @test Set(p.id for p in revision_parents(graph, r3)) == Set([r1, r2])
    @test Set(c.id for c in revision_children(graph, r0)) == Set([r1, r2])
    @test isempty(revision_children(graph, r3))
    @test Set(a.id for a in revision_ancestors(graph, r3)) == Set([r0, r1, r2])
    @test r3 ∉ (a.id for a in revision_ancestors(graph, r3))
    @test Set(d.id for d in revision_descendants(graph, r0)) == Set([r1, r2, r3])
    @test r0 ∉ (d.id for d in revision_descendants(graph, r0))

    moved = ArchiveGraph(
        graph.objects;
        heads = [WorkflowHead(WorkflowHeadId("head-main"), :main, r3)],
        revisions = graph.revisions,
        runs = graph.runs,
        events = graph.events,
    )
    @test moved.objects == graph.objects
    @test moved.revisions == graph.revisions
    @test moved.heads[1].revision_id == r3
    @test graph.heads[1].revision_id == r1
    @test find_objects(moved, r1) == find_objects(graph, r1)
end

@testset "revision parent dangling and cycle diagnostics" begin
    r0 = RevisionId(REV_1)
    r1 = RevisionId(REV_2)
    r2 = RevisionId(REV_3)

    dangling = validate(ArchiveGraph(
        ArchiveObject[];
        revisions = [RevisionRecord(r1; parents = [r0])],
    ))
    @test any(d -> d.code === :dangling_parent, dangling.diagnostics)
    @test !isvalid(dangling)

    self_cycle = validate(ArchiveGraph(
        ArchiveObject[];
        revisions = [RevisionRecord(r0; parents = [r0])],
    ))
    @test any(d -> d.code === :cycle, self_cycle.diagnostics)

    loop = validate(ArchiveGraph(
        ArchiveObject[];
        revisions = [
            RevisionRecord(r0; parents = [r1]),
            RevisionRecord(r1; parents = [r0]),
        ],
    ))
    @test any(d -> d.code === :cycle, loop.diagnostics)

    three = validate(ArchiveGraph(
        ArchiveObject[];
        revisions = [
            RevisionRecord(r0; parents = [r2]),
            RevisionRecord(r1; parents = [r0]),
            RevisionRecord(r2; parents = [r1]),
        ],
    ))
    @test any(d -> d.code === :cycle, three.diagnostics)

    @test revision_ancestors(
        ArchiveGraph(ArchiveObject[]; revisions = [RevisionRecord(r0)]),
        r1,
    ) == RevisionRecord[]
end
