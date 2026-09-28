# One read session for layered state/run/event (and derived) inspection.

function _revision_keys(state)
    return [(
        revision.id.value,
        [parent.value for parent in revision.parents],
        revision.run_id === nothing ? nothing : revision.run_id.value,
        revision.plan_id === nothing ? nothing : revision.plan_id.value,
    ) for revision in state.revisions]
end

function _head_keys(state)
    return [(head.id.value, String(head.name), head.revision_id.value) for head in state.heads]
end

function _counted_archive_inspect(body::Function)
    ext = Base.get_extension(Episteme, :EpistemeJLD2Ext)
    opens = Ref(0)
    decodes = Ref(0)
    result = task_local_storage(ext._ARCHIVE_READ_OPENS, opens) do
        task_local_storage(ext._ARCHIVE_CORE_DECODES, decodes) do
            body()
        end
    end
    return result, opens[], decodes[]
end

@testset "layered history inspect uses one archive session" begin
    mktempdir() do dir
        graph, _, _ = _event_history_fixture()
        schemas = SchemaRegistry([_mesh_def()])
        path = joinpath(dir, "layered-event.ah5")
        write_event_archive(path, graph; schemas = schemas)

        state_view = inspect_archive(path, ArchiveStateHistory)
        run_view = inspect_archive(path, ArchiveRunHistory)
        layered, opens, decodes = _counted_archive_inspect() do
            inspect_archive(path, ArchiveEventHistory)
        end

        @test opens == 1
        @test decodes == 1
        @test layered.identified
        @test layered.feature_declared
        @test layered.valid
        @test layered.path == state_view.path
        @test Episteme._state_object_storage.(layered.state.objects) ==
            Episteme._state_object_storage.(state_view.state.objects)
        @test Episteme._state_object_storage.(layered.state.objects) ==
            Episteme._state_object_storage.(run_view.state.objects)
        @test _revision_keys(layered.state) == _revision_keys(state_view.state)
        @test _head_keys(layered.state) == _head_keys(run_view.state)
        @test layered.externals == run_view.externals
        @test layered.diagnostics == run_view.diagnostics
        @test Episteme._event_record_storage.(layered.events) ==
            Episteme._event_record_storage.(graph.events)
        @test Episteme._write_record_storage.(layered.writes) ==
            Episteme._write_record_storage.(graph.writes)
        @test Episteme._log_stream_storage.(layered.log_streams) ==
            Episteme._log_stream_storage.(graph.log_streams)
        @test Episteme._run_record_storage.(layered.runs) ==
            Episteme._run_record_storage.(run_view.runs)

        _, state_opens, state_decodes = _counted_archive_inspect() do
            inspect_archive(path, ArchiveStateHistory)
        end
        @test state_opens == 1
        @test state_decodes == 1

        _, run_opens, run_decodes = _counted_archive_inspect() do
            inspect_archive(path, ArchiveRunHistory)
        end
        @test run_opens == 1
        @test run_decodes == 1

        missing, missing_opens, missing_decodes = _counted_archive_inspect() do
            inspect_archive(joinpath(dir, "absent.ah5"), ArchiveEventHistory)
        end
        @test missing_opens == 0
        @test missing_decodes == 0
        @test !missing.identified
        @test any(diagnostic -> diagnostic.code === :missing_archive, missing.diagnostics)

        plain = ArchiveGraph(
            [_obj(:delone, "mesh", ID_GEOM, REV_1; content = STATE_CONTENT_A, uuid = UUID_DELONE)];
            revisions = [RevisionRecord(RevisionId(REV_1))],
        )
        state_path = joinpath(dir, "state-only.ah5")
        write_state_archive(state_path, plain; schemas = schemas)
        state_only_state = inspect_archive(state_path, ArchiveStateHistory)
        state_only, state_only_opens, state_only_decodes = _counted_archive_inspect() do
            inspect_archive(state_path, ArchiveEventHistory)
        end
        @test state_only_opens == 1
        @test state_only_decodes == 1
        @test state_only.identified
        @test state_only.valid
        @test !state_only.feature_declared
        @test Episteme._state_object_storage.(state_only.state.objects) ==
            Episteme._state_object_storage.(state_only_state.state.objects)
        @test _revision_keys(state_only.state) == _revision_keys(state_only_state.state)
        @test isempty(state_only.runs)
        @test isempty(state_only.events)
        @test isempty(state_only.writes)
        @test isempty(state_only.log_streams)

        summary_path = joinpath(dir, "summary-without-events.ah5")
        write_state_archive(summary_path, graph; schemas = schemas)
        summary, summary_opens, summary_decodes = _counted_archive_inspect() do
            inspect_archive(summary_path, ArchiveEventHistory)
        end
        @test summary_opens == 1
        @test summary_decodes == 1
        @test summary.identified
        @test !summary.feature_declared
        @test !summary.valid
        @test summary.state === nothing
        @test any(diagnostic -> diagnostic.code === :run_history_records_missing, summary.diagnostics)
        @test any(diagnostic -> diagnostic.code === :event_history_records_missing, summary.diagnostics)

        derived_graph, records, _, _, _, _, _, _ = _derived_history_fixture()
        derived_schemas = SchemaRegistry([_mesh_def(), _field_def()])
        derived_path = joinpath(dir, "layered-derived.ah5")
        write_derived_archive(derived_path, derived_graph, records; schemas = derived_schemas)
        derived_run = inspect_archive(derived_path, ArchiveRunHistory)
        derived, derived_opens, derived_decodes = _counted_archive_inspect() do
            inspect_archive(derived_path, ArchiveDerivedHistory)
        end
        @test derived_opens == 1
        @test derived_decodes == 1
        @test derived.valid
        @test derived.feature_declared
        @test Episteme._state_object_storage.(derived.state.objects) ==
            Episteme._state_object_storage.(derived_run.state.objects)
        @test Episteme._run_record_storage.(derived.runs) ==
            Episteme._run_record_storage.(derived_run.runs)
        @test Episteme._derived_record_storage.(derived.artifacts) ==
            Episteme._derived_record_storage.(records)
        @test derived.diagnostics == derived_run.diagnostics
    end
end
