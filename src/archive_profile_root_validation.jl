# Additional v1 invariants for configurable AH5 inspectable roots.
#
# The profile record itself lives at `episteme/profile`; all other profile-owned
# roots stay inside the reserved `episteme/...` subtree.  The first argument is
# typed deliberately so this method tightens the generic validator defined in
# archive_profile.jl without duplicating the whole profile implementation.
function _validate_roots!(
    diagnostics::AbstractVector{DiagnosticMessage},
    roots::ArchiveProfileRoots,
)
    used = Pair{Symbol,String}[]
    profile_prefix = string(AH5_PROFILE_KEY, "/")

    for (name, path) in (
        (:namespaces, roots.namespaces),
        (:schemas, roots.schemas),
        (:history, roots.history),
        (:provenance, roots.provenance),
        (:externals, roots.externals),
    )
        stripped = String(strip(path))
        reserved = startswith(stripped, "episteme/")
        profile_subtree = stripped == AH5_PROFILE_KEY || startswith(stripped, profile_prefix)
        malformed = isempty(stripped) || occursin("//", stripped)

        if malformed || !reserved || profile_subtree
            push!(diagnostics, error_diagnostic(
                :invalid_archive_root,
                "AH5 $name root $(repr(path)) must be a usable path inside the reserved episteme/... subtree and outside episteme/profile/...";
                root = name,
                path = path,
            ))
            continue
        end

        conflict = findfirst(used) do existing
            other = last(existing)
            stripped == other ||
                startswith(stripped, string(other, "/")) ||
                startswith(other, string(stripped, "/"))
        end
        if conflict !== nothing
            other_name, other_path = used[conflict]
            push!(diagnostics, error_diagnostic(
                :invalid_archive_root,
                "AH5 $name root $(repr(path)) overlaps AH5 $other_name root $(repr(other_path))";
                root = name,
                path = path,
                conflicting_root = other_name,
                conflicting_path = other_path,
            ))
            continue
        end

        push!(used, name => stripped)
    end
    return diagnostics
end
