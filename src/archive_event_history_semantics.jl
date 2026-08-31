# ---------------------------------------------------------------------------
# Event-history semantic refinements (#85)
# ---------------------------------------------------------------------------

# EventRecord.object_refs keep the existing ArchiveGraph contract: they point to
# archived scientific object envelopes. ExternalRequirement is not a second
# direct event-reference namespace in this slice. `_validate_event_history`
# normalizes externals to this exact vector type, so this method wins over the
# generic helper in archive_event_history.jl without replacing that method.
function _event_object_ref_resolves(
    graph::ArchiveGraph,
    ::Vector{ExternalRequirement},
    ref::ObjectRef,
)
    return _reference_resolves(graph, ref)
end

# The physical tagged representation reconstructs captured portable stand-ins
# first. Convert container stand-ins (notably PortableDict) back to ordinary
# portable Julia containers while deliberately leaving package-coded
# PortableEncoded values undecoded for the generic forensic reader.
function _restore_event_payload(value::NamedTuple)
    captured = _value_from_namedtuple(value)
    payload = _restore_value(captured; decode = false)
    payload isa NamedTuple || throw(ArgumentError(
        "AH5 event payload must restore as a NamedTuple",
    ))
    return payload
end

# `writer_token` is a durability/writer identity, not automatically a secret.
# Preserve ordinary lease ids/UUIDs, but do not archive values that themselves
# match the generic credential patterns used elsewhere in Episteme.
function _validate_event_writes!(
    diagnostics::Vector{DiagnosticMessage},
    graph::ArchiveGraph,
    writes::Vector{WriteTransaction},
)
    invoke(
        _validate_event_writes!,
        Tuple{Any,Any,Any},
        diagnostics,
        graph,
        writes,
    )
    for tx in writes
        token = tx.writer_token
        token === nothing && continue
        _looks_like_secret_value(token) || continue
        push!(diagnostics, error_diagnostic(
            :credential_like_content,
            "credential-like content is not allowed in persisted writer tokens";
            scope = tx.scope,
            run_id = tx.run_id === nothing ? nothing : tx.run_id.value,
            sequence = tx.sequence,
        ))
    end
    return diagnostics
end

# A lower-layer archive can carry summary counts for history that its physical
# feature set did not persist. A full event-history view must never turn that
# into a silently partial graph.
function _empty_event_history_inspection(
    path::AbstractString,
    identified::Bool,
    declared::Bool,
    state::ArchiveStateHistory,
    runs::Vector{RunRecord},
    externals::Vector{ExternalRequirement},
    diagnostics::Vector{DiagnosticMessage},
)
    core = inspect_archive(path)
    if core.history.runs != length(runs)
        push!(diagnostics, error_diagnostic(
            :run_history_records_missing,
            "AH5 history summary reports run provenance that is not present in the reconstructed run-history layer";
            summary = core.history.runs,
            records = length(runs),
        ))
    end
    if !declared &&
            (core.history.events != 0 || core.history.writes != 0 || core.history.log_streams != 0)
        push!(diagnostics, error_diagnostic(
            :event_history_records_missing,
            "AH5 history summary reports event/write/log provenance but no event-history records were persisted";
            events = core.history.events,
            writes = core.history.writes,
            log_streams = core.history.log_streams,
        ))
    end
    valid = identified && !any(d -> d.severity === :error, diagnostics)
    return ArchiveEventHistoryInspection(
        String(path),
        identified,
        declared,
        valid,
        valid ? state : nothing,
        valid ? copy(runs) : RunRecord[],
        EventRecord[],
        WriteTransaction[],
        LogStreamRecord[],
        ExternalRequirement[externals...],
        diagnostics,
    )
end
