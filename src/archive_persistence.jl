# ---------------------------------------------------------------------------
# AH5 persistence entry points and their fail-closed owner stubs
#
# Episteme's semantics, identities, schemas, history vocabulary, and record
# encoders/decoders are stdlib-only. The only part that needs JLD2 is the file
# I/O of the `.ah5` profile, so JLD2 is a `[weakdeps]` package and every writer
# and reader that opens a file lives in `ext/EpistemeJLD2Ext*.jl`.
#
# These generic fallbacks are deliberately broad. EpistemeJLD2Ext adds the
# more-specific methods when JLD2 is loaded; without it every persistence entry
# point fails closed with the same actionable diagnostic. A silent no-op would
# be worse than a hard dependency: an archive that is never written must not
# look like an archive that was written.
# ---------------------------------------------------------------------------

"""Return the fail-closed error used by the optional AH5 persistence path."""
function _missing_jld2_error(name::AbstractString)
    return ErrorException(
        "$name requires JLD2.jl. Add JLD2 and run `using JLD2` after " *
        "`using Episteme` to activate the EpistemeJLD2Ext extension.",
    )
end

"""
    write_archive(path; graph=nothing, namespaces=nothing, schemas=nothing,
                  externals=(), profile=nothing, kwargs...)
    write_archive(path, manifest::RevisionIntegrityManifest; kwargs...)
    write_archive(path, manifests::AbstractVector{<:RevisionIntegrityManifest}; kwargs...)

Create a JLD2-backed AH5 file. The path is created by JLD2. Existing
paths are refused. Domain payloads are not written. Logical metadata is
validated before the file is created; inspectable groups follow
`profile.roots`. Records are stored as `plain=true`-safe values.

The manifest forms create that normal archive and then append clean,
successful revision integrity manifests under the optional
`episteme/integrity` feature. If the integrity append fails, the
newly-created file is removed rather than published partially.

Requires JLD2: run `using JLD2` to load `EpistemeJLD2Ext`.
"""
function write_archive(args...; kwargs...)
    throw(_missing_jld2_error("write_archive"))
end

"""
    inspect_archive(path) -> ArchiveInspection
    inspect_archive(path, RevisionIntegrityManifest) -> ArchiveIntegrityInspection
    inspect_archive(path, ArchiveStateHistory) -> ArchiveStateHistoryInspection
    inspect_archive(path, ArchiveRunHistory) -> ArchiveRunHistoryInspection
    inspect_archive(path, ArchiveEventHistory) -> ArchiveEventHistoryInspection

Read AH5 profile metadata without domain packages or payload load.
Forensic JLD2 `plain=true` is the default reader. The tiny profile is
validated first; unsupported versions or required features return an
identified archive without decoding remaining roots. Full Julia-native
object reconstruction is not this API.

The second-argument forms interpret one optional root each — integrity
manifests, authoritative state history, run/activity/restart provenance, or
event/write/log provenance — and each root is decoded only when the profile
explicitly declares its feature. Old archives without an optional feature
remain valid and return empty records. Scientific payloads and raw log bytes
are never loaded.

Requires JLD2: run `using JLD2` to load `EpistemeJLD2Ext`.
"""
function inspect_archive(args...; kwargs...)
    throw(_missing_jld2_error("inspect_archive"))
end

"""
    write_state_archive(path, graph; kwargs...)

Create a normal AH5 archive and append authoritative payload-free object,
revision, and head records under the optional state-history feature. Full
run/activity/event provenance remains a later persistence slice.

Requires JLD2: run `using JLD2` to load `EpistemeJLD2Ext`.
"""
function write_state_archive(args...; kwargs...)
    throw(_missing_jld2_error("write_state_archive"))
end

"""
    write_run_archive(path, graph; kwargs...)

Create an AH5 archive with both authoritative state-history and run/activity
provenance records. Event/write/log provenance remains a later extension.

Requires JLD2: run `using JLD2` to load `EpistemeJLD2Ext`.
"""
function write_run_archive(args...; kwargs...)
    throw(_missing_jld2_error("write_run_archive"))
end

"""
    write_event_archive(path, graph; kwargs...)

Create an AH5 archive with state, run/activity/restart, and generic event/write/
log provenance metadata. Event payloads must be portable; raw log bytes are not
embedded by this method.

Requires JLD2: run `using JLD2` to load `EpistemeJLD2Ext`.
"""
function write_event_archive(args...; kwargs...)
    throw(_missing_jld2_error("write_event_archive"))
end
