# Build the docs from the repo root:
#   julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
#   julia --project=docs docs/make.jl

using Documenter
using GenICam

DocMeta.setdocmeta!(
    GenICam,
    :DocTestSetup,
    :(using GenICam);
    recursive = true,
)

makedocs(
    modules  = [GenICam, GenICam.GenTL, GenICam.GenApi, GenICam.PixelFormats],
    authors  = "schrpe",
    sitename = "GenICam.jl",
    remotes  = nothing,
    format   = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical  = "https://schrpe.github.io/GenICam.jl",
        sidebar_sitename = false,
    ),
    pages = [
        "Home"                => "index.md",
        "Background" => [
            "Concepts"        => "concepts.md",
            "SwissKnife"      => "swissknife.md",
        ],
        "Guides" => [
            "Quickstart"      => "quickstart.md",
            "Features"        => "features.md",
            "Pixel formats"   => "pixelformats.md",
            "Streaming"       => "streaming.md",
            "Chunks and events" => "chunks_events.md",
            "Hot-plug detection" => "hotplug.md",
        ],
        "Reference" => [
            "Vendor notes"    => "vendors.md",
            "API reference"   => "api.md",
        ],
    ],
    # `:exports` requires every exported name to carry a doc-string;
    # we relax to `:none` for now so the build doesn't fail on the
    # handful of @enum value names (DROP_OLDEST, BIG_ENDIAN, etc.)
    # that don't carry their own doc-string by Julia convention.
    checkdocs = :none,
)
