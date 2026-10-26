using Documenter

# Durable contract chapters stay in docs/*.md, where the repository already
# links them. Copy them into the Documenter source tree for this build only.
const CHAPTERS = [
    "archive-ownership.md" => "Ownership",
    "semantic-tree.md" => "Semantic tree",
    "declarative-contracts.md" => "Declarative contracts",
    "archive-envelope.md" => "Envelope",
    "archive-namespaces.md" => "Namespaces",
    "archive-schemas.md" => "Schemas",
    "archive-profile.md" => "AH5 profile",
    "archive-lifecycle.md" => "Lifecycle",
    "archive-events.md" => "Events",
    "workflow.md" => "Workflow",
    "portable-documents.md" => "Portable documents",
    "archive-checkout.md" => "Checkout",
    "archive-purge.md" => "Purge",
    "derived-artifacts.md" => "Derived artifacts",
    "schema-migration.md" => "Schema migration",
    "capsule-planning.md" => "Capsule planning",
    "capsule-archives.md" => "Capsules",
    "software-environments.md" => "Software environments",
    "execution-contexts.md" => "Execution contexts",
    "archive-views.md" => "Views",
    "archive-state-history.md" => "State history",
    "archive-run-history.md" => "Run history",
    "archive-event-history.md" => "Event history",
    "content-integrity.md" => "Content identity",
    "external-integrity.md" => "External integrity",
    "revision-integrity.md" => "Revision integrity",
    "archive-integrity.md" => "Integrity persistence",
]

const included = joinpath(@__DIR__, "src", "included")
rm(included; force = true, recursive = true)
mkpath(included)
on_disk = Set(filter(name -> endswith(name, ".md"), readdir(@__DIR__)))
listed = Set(first.(CHAPTERS))
if on_disk != listed
    error(
        "docs/*.md does not match the manual chapter list\n" *
        "only on disk: $(sort!(collect(setdiff(on_disk, listed))))\n" *
        "only listed: $(sort!(collect(setdiff(listed, on_disk))))",
    )
end
for (name, _) in CHAPTERS
    cp(joinpath(@__DIR__, name), joinpath(included, name))
end

load_error = ""
episteme_loaded = false
try
    @eval using Episteme
    global episteme_loaded = true
catch err
    global load_error = sprint(showerror, err)
    @warn "Episteme did not load; building the manual without code modules" error = load_error
end

pages = [
    "Home" => "index.md",
    "Architecture" => "architecture.md",
    "Guide" => "guide.md",
    "Public API" => "api.md",
    "Record chapters" => [title => joinpath("included", name) for (name, title) in CHAPTERS],
]

makedocs(;
    sitename = "Episteme",
    authors = "Jukka Aho",
    modules = episteme_loaded ? [Episteme] : Module[],
    doctest = false,
    # archive-lifecycle.md has one [`ArchiveGraph`](@ref) and this manual does
    # not expand that chapter into @docs blocks.
    warnonly = [:missing_docs, :cross_references],
    format = Documenter.HTML(;
        prettyurls = false,
        size_threshold = nothing,
    ),
    pages = pages,
)

println(episteme_loaded ? "Episteme loaded" : "Episteme load failed: " * load_error)
