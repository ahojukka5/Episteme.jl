# ---------------------------------------------------------------------------
# EpistemeJLD2Ext — JLD2-backed `.ah5` file I/O
#
# Loaded when the user runs `using JLD2` after `using Episteme`. Episteme's
# semantics, identities, schemas, history vocabulary, and record
# encoders/decoders are stdlib-only; JLD2 is only needed to create and read
# the file. Everything that opens a path therefore lives here, and the owner
# package keeps fail-closed stubs in `src/archive_persistence.jl`.
#
# The methods defined here are strictly more specific than those stubs, so
# loading this extension adds methods instead of overwriting them: the
# `write_archive(path::String; ...)` external-preflight specialization in the
# owner package keeps working unchanged and reaches this writer through its
# existing `invoke`.
#
# Behaviour with JLD2 loaded is identical to the pre-extension package: same
# functions, same signatures, same results.
# ---------------------------------------------------------------------------

module EpistemeJLD2Ext

import JLD2
using Episteme

# Record shaping, validation, and decoding stay in Episteme. These are the
# owner-side helpers the file-opening entry points below call.
using Episteme:
    _count_key,
    _empty_event_history_inspection,
    _empty_inspection,
    _empty_integrity_inspection,
    _empty_run_history_inspection,
    _empty_state_history_inspection,
    _event_history_counts_exist,
    _external_storage,
    _externals_vector,
    _history_storage,
    _inspect_open_archive,
    _integrity_manifest_storage,
    _integrity_manifests,
    _jld2_get,
    _namespace_listing_storage,
    _profile_storage,
    _profile_with_event_history,
    _profile_with_integrity,
    _profile_with_run_history,
    _profile_with_state_history,
    _provenance_storage,
    _published_profile,
    _read_event_history,
    _read_indexed,
    _read_run_history,
    _read_state_history,
    _refuse_event_history_root_collision,
    _refuse_integrity_archive_mismatch,
    _refuse_integrity_root_collision,
    _refuse_invalid_payload,
    _refuse_invalid_profile,
    _refuse_run_history_root_collision,
    _refuse_state_history_root_collision,
    _refuse_unstorable_integrity,
    _restore_integrity_manifest,
    _schema_listing_storage,
    _state_history_counts_exist,
    _state_history_from_graph,
    _typed_vector,
    _validate_event_history,
    _validate_run_history,
    _validate_state_history,
    _write_event_history!,
    _write_indexed!,
    _write_run_history!,
    _write_state_history!

include("EpistemeJLD2Ext_archive_profile.jl")
include("EpistemeJLD2Ext_archive_integrity_persistence.jl")
include("EpistemeJLD2Ext_archive_integrity_semantics.jl")
include("EpistemeJLD2Ext_archive_state_history.jl")
include("EpistemeJLD2Ext_archive_run_history.jl")
include("EpistemeJLD2Ext_archive_event_history.jl")
include("EpistemeJLD2Ext_capsule_archive.jl")
include("EpistemeJLD2Ext_archive_software_environments.jl")
include("EpistemeJLD2Ext_archive_execution_contexts.jl")

end # module EpistemeJLD2Ext
