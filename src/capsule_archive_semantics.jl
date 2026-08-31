# ---------------------------------------------------------------------------
# Capsule materialization semantic refinements (#87)
# ---------------------------------------------------------------------------

# Capsule materialization composes the event-history writer with a later
# integrity append rather than entering through #77's positional writer. Run
# the same integrity-root collision guard when the final ArchiveProfile is
# assembled so custom inspectable roots cannot occupy episteme/integrity.
function _capsule_archive_profile(profile::ArchiveProfile, capsule_archive_id)
    result = invoke(
        _capsule_archive_profile,
        Tuple{Any,Any},
        profile,
        capsule_archive_id,
    )
    _refuse_integrity_root_collision(result)
    return result
end
