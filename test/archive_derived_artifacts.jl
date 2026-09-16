# AH5 derived/debug artifact provenance (#32).

function _derived_history_fixture()
    r1 = RevisionId(REV_1)
    r2 = RevisionId(REV_2)
    mesh = _obj(:delone, "mesh", ID_MESH, REV_1; content = "mesh-bytes", uuid = UUID_DELONE)
    plot = _obj(:oodi, "field", ID_FIELD, REV_1; content = "plot-bytes", uuid = UUID_OODI)
    overlay = _obj(:oodi, "field", ID_SPACE, REV_1; content = "debug-bytes", uuid = UUID_OODI)
    note = _obj(:oodi, "field", ID_POST, REV_1; content = "note-bytes", uuid = UUID_OODI)
    coarse = _obj(:oodi, "field", ID_SECTOR, REV_1; content = "field-coarse", uuid = UUID_OODI)
    fine = _obj(:oodi, "field", ID_SECTOR, REV_2; content = "field-fine", uuid = UUID_OODI)
    activity = ActivityRecord(ActivityId("act-derived"), RunId("run-derived"), :postprocess)
    run = RunRecord(
        RunId("run-derived");
        revision_id = r2,
        status = :completed,
        activities = [activity],
    )
    graph = ArchiveGraph(
        [mesh, plot, overlay, note, coarse, fine];
        revisions = [RevisionRecord(r1), RevisionRecord(r2; parents = [r1])],
        runs = [run],
    )
    mesh_input = DerivedInputRef(mesh.object_id, r1; content_id = mesh.content_id)
    records = [
        DerivedArtifactRecord(
            plot.object_id,
            plot.revision_id,
            :visualization;
            inputs = [mesh_input],
            run_id = run.id,
            activity_id = activity.id,
            operation = :postprocess,
            parameters = (; cmap = "viridis"),
            schema = plot.schema,
            retention = :visualization,
            units = "1",
            value_shape = (nothing,),
            artifact = ArtifactRef(
                :png;
                path = "preview.png",
                uri = "file://preview.png",
                description = "plot",
                renderer = "generic",
            ),
        ),
        DerivedArtifactRecord(
            overlay.object_id,
            overlay.revision_id,
            :debug;
            inputs = [mesh_input],
            run_id = run.id,
            activity_id = activity.id,
            operation = :postprocess,
            retention = :debug,
            diagnostics = [warning_diagnostic(:noisy, "debug overlay is noisy"; cells = 3)],
        ),
        DerivedArtifactRecord(
            note.object_id,
            note.revision_id,
            :annotation;
            inputs = [mesh_input],
            run_id = run.id,
            activity_id = activity.id,
            operation = :postprocess,
            retention = :forensic,
            status = :failed,
            diagnostics = [error_diagnostic(:incomplete, "annotation source was incomplete")],
        ),
        DerivedArtifactRecord(
            coarse.object_id,
            coarse.revision_id,
            :derived;
            inputs = [mesh_input],
            run_id = run.id,
            activity_id = activity.id,
            operation = :postprocess,
            parameters = (; bins = 10),
            retention = :replaceable,
        ),
        DerivedArtifactRecord(
            fine.object_id,
            fine.revision_id,
            :derived;
            inputs = [
                mesh_input,
                DerivedInputRef(coarse.object_id, r1; content_id = coarse.content_id),
            ],
            run_id = run.id,
            activity_id = activity.id,
            operation = :postprocess,
            parameters = (; bins = 40),
            retention = :pinned,
        ),
    ]
    return graph, records, r1, r2, mesh, plot, coarse, fine
end

@testset "AH5 derived artifacts round-trip ancestry retention and inspection" begin
    mktempdir() do dir
        graph, records, _, r2, _, plot, coarse, fine = _derived_history_fixture()
        schemas = SchemaRegistry([_mesh_def(), _field_def()])
        @test isvalid(validate(records, graph))

        path = joinpath(dir, "derived-history.ah5")
        write_derived_archive(path, graph, records; schemas = schemas)

        core = inspect_archive(path)
        @test core.identified
        @test AH5_STATE_HISTORY_FEATURE in core.profile.features
        @test AH5_RUN_HISTORY_FEATURE in core.profile.features
        @test AH5_DERIVED_ARTIFACTS_FEATURE in core.profile.features

        view = inspect_archive(path, ArchiveDerivedHistory)
        @test view.identified
        @test view.feature_declared
        @test isvalid(view)
        @test isvalid(validate(view))
        @test length(view.artifacts) == 5
        @test [record.role for record in view.artifacts] ==
            [:visualization, :debug, :annotation, :derived, :derived]
        @test view.artifacts[1].parameters == (; cmap = "viridis")
        @test view.artifacts[1].value_shape == (nothing,)
        @test view.artifacts[1].artifact.path == "preview.png"
        @test view.artifacts[1].artifact.uri == "file://preview.png"
        @test view.artifacts[1].artifact.metadata == (; renderer = "generic")
        @test view.artifacts[3].status === :failed
        @test view.artifacts[3].diagnostics[1].code === :incomplete
        @test view.artifacts[4].parameters != view.artifacts[5].parameters
        @test view.artifacts[4].object_id == view.artifacts[5].object_id
        @test view.artifacts[4].revision_id != view.artifacts[5].revision_id

        explained = report(view.artifacts[1])
        @test occursin(":visualization", explained.summary)
        @test explained.metadata.parameters == (; cmap = "viridis")
        @test !occursin("plot-bytes", explained.summary)
        @test !occursin("plot-bytes", report(view).summary)

        ancestors = derived_ancestry(view.artifacts[5], view)
        @test [record.object_id for record in ancestors] == [coarse.object_id]
        reconstructed = reconstruct_graph(view)
        @test isvalid(validate(view.artifacts, reconstructed))

        roots = [RetentionRoot(r2)]
        original_plan = plan_purge(graph, roots; derived = records)
        reopened_plan = plan_purge(reconstructed, roots; derived = view.artifacts)
        @test [c.class for c in reopened_plan.classifications] ==
            [c.class for c in original_plan.classifications]
        class_of(object, plan) = only(
            c.class for c in plan.classifications
            if c.object_id == object.object_id && c.revision_id == object.revision_id
        )
        @test class_of(plot, original_plan) === :purgeable_visualization
        @test class_of(fine, original_plan) === :reachable

        raw = JLD2.jldopen(path, "r"; plain = true) do file
            file["$(AH5_DERIVED_ARTIFACTS_KEY)/1"]
        end
        @test Symbol(raw.parameters.portable_kind) === :namedtuple
        @test !haskey(raw, :payload_bytes)
    end
end

@testset "derived persistence refuses invalid cycles dangling and nonportable values" begin
    mktempdir() do dir
        graph, records, r1, _, _, _, _, fine = _derived_history_fixture()
        schemas = SchemaRegistry([_mesh_def(), _field_def()])
        child = records[5]
        cyclic = DerivedArtifactRecord(
            records[4].object_id,
            records[4].revision_id,
            :derived;
            inputs = [DerivedInputRef(child.object_id, child.revision_id; content_id = fine.content_id)],
            run_id = child.run_id,
            activity_id = child.activity_id,
            operation = child.operation,
        )
        cycle_path = joinpath(dir, "cycle.ah5")
        @test_throws ArgumentError write_derived_archive(
            cycle_path, graph, [cyclic, child]; schemas = schemas,
        )
        @test !ispath(cycle_path)

        dangling = DerivedArtifactRecord(
            records[3].object_id,
            records[3].revision_id,
            :annotation;
            inputs = [DerivedInputRef(ObjectId(ID_GEOM), r1)],
            run_id = child.run_id,
            activity_id = child.activity_id,
            operation = child.operation,
        )
        dangling_path = joinpath(dir, "dangling.ah5")
        @test_throws ArgumentError write_derived_archive(
            dangling_path, graph, [dangling]; schemas = schemas,
        )
        @test !ispath(dangling_path)

        bad = DerivedArtifactRecord(
            records[1].object_id,
            records[1].revision_id,
            :visualization;
            inputs = records[1].inputs,
            run_id = child.run_id,
            activity_id = child.activity_id,
            operation = child.operation,
            parameters = (; handle = Ref(1)),
            retention = :visualization,
        )
        bad_path = joinpath(dir, "nonportable.ah5")
        @test_throws ArgumentError write_derived_archive(
            bad_path, graph, [bad]; schemas = schemas,
        )
        @test !ispath(bad_path)

        secret = DerivedArtifactRecord(
            records[1].object_id,
            records[1].revision_id,
            :visualization;
            inputs = records[1].inputs,
            run_id = child.run_id,
            activity_id = child.activity_id,
            operation = child.operation,
            parameters = (; api_token = "ghp_abcdefghijklmnopqrstuvwxyz0123"),
            retention = :visualization,
        )
        secret_path = joinpath(dir, "secret.ah5")
        @test_throws ArgumentError write_derived_archive(
            secret_path, graph, [secret]; schemas = schemas,
        )
        @test !ispath(secret_path)
    end
end

@testset "derived AH5 feature is optional and fails closed when corrupt" begin
    mktempdir() do dir
        graph, records, _, _, _, _, _, _ = _derived_history_fixture()
        schemas = SchemaRegistry([_mesh_def(), _field_def()])

        run_only = joinpath(dir, "run-only.ah5")
        write_run_archive(run_only, graph; schemas = schemas)
        absent = inspect_archive(run_only, ArchiveDerivedHistory)
        @test absent.identified
        @test !absent.feature_declared
        @test isvalid(absent)
        @test isempty(absent.artifacts)

        path = joinpath(dir, "derived-corrupt.ah5")
        write_derived_archive(path, graph, records; schemas = schemas)
        JLD2.jldopen(path, "r+") do file
            raw = file["$(AH5_DERIVED_ARTIFACTS_KEY)/5"]
            object_ids = String[String(item) for item in raw.input_object_ids]
            object_ids[1] = "missing-object"
            delete!(file, "$(AH5_DERIVED_ARTIFACTS_KEY)/5")
            file["$(AH5_DERIVED_ARTIFACTS_KEY)/5"] = merge(
                raw,
                (; input_object_ids = object_ids),
            )
        end
        view = inspect_archive(path, ArchiveDerivedHistory)
        @test view.identified
        @test view.feature_declared
        @test !isvalid(view)
        @test isempty(view.artifacts)
        @test any(d -> d.code === :dangling_derived_input, view.diagnostics)
        @test_throws ArgumentError reconstruct_graph(view)

        declared = joinpath(dir, "declared-only.ah5")
        write_archive(
            declared;
            profile = ArchiveProfile(; features = (AH5_DERIVED_ARTIFACTS_FEATURE,)),
        )
        missing = inspect_archive(declared, ArchiveDerivedHistory)
        @test missing.identified
        @test missing.feature_declared
        @test !isvalid(missing)
        @test any(d -> d.code in (
            :derived_history_run_missing,
            :derived_history_state_missing,
            :corrupt_derived_artifacts,
        ), missing.diagnostics)

        @test_throws ArgumentError write_derived_archive(
            joinpath(dir, "required.ah5"),
            graph,
            records;
            schemas = schemas,
            required_features = (AH5_DERIVED_ARTIFACTS_FEATURE,),
        )
    end
end
