# GenICam.jl

[![Tests](https://github.com/schrpe/GenICam.jl/actions/workflows/Tests.yml/badge.svg)](https://github.com/schrpe/GenICam.jl/actions/workflows/Tests.yml)
[![Documentation](https://github.com/schrpe/GenICam.jl/actions/workflows/Documentation.yml/badge.svg)](https://schrpe.github.io/GenICam.jl)

Pure-Julia implementation of the EMVA **GenICam** standard family —
device discovery, configuration, image acquisition, and per-frame
metadata for any vendor's machine-vision camera that ships a GenTL
producer DLL.

| | |
|---|---|
| **Standard** | GenTL 1.5, GenApi 1.1, SFNC, PFNC |
| **Platforms** | Windows x64, Linux x64, macOS x64 |
| **Julia** | 1.12+ |
| **Status** | Feature complete, live-tested |
| **License** | MIT |

## Quick start

```julia
using GenICam, GenICam.GenTL

# Find an installed producer (Balluff, MATRIX VISION, Basler, ...) and load it.
api = load_producer(first(list_producers()))
producer = Producer(api)

# Pick the first visible camera, open it.
info = first(list_cameras(producer))
cam = open_camera(producer, info.interface, info.device)

# Configure: AOI, pixel format, exposure.
set_aoi!(cam; width = 640, height = 480)
cam.PixelFormat = "Mono8"
set_exposure!(cam, 5000.0)        # microseconds

# Single frame.
frame = grab(cam)
@show size(frame.image) eltype(frame.image) frame.pixel_format

# Or continuous streaming.
stream(cam) do channel
    for img in Iterators.take(channel, 100)
        process(img.image)
    end
end

close(cam); close(producer); close(api)
```

## What works

- **GenTL consumer** — pure-Julia binding for the EMVA GenTL 1.5 Producer
  ABI, dynamically loading any vendor `.cti` DLL via `Libdl`. All
  exported symbols, all enums, all packed structs.

- **GenApi node-map** — full GenApi 1.1 implementation. 15 concrete
  node types (`Integer`/`Float`/`Boolean`/`String`/`Enumeration`/`Command`,
  six register flavours, four formula-driven types, plus `Category` and
  `StructEntry`). Three-pass parser handles forward references,
  invalidator wiring, and formula compilation. SwissKnife evaluator
  with the full operator set (`+ - * / % ** & | ^ ~ << >> && || == != = <> < > <= >= ?:`)
  plus all spec'd built-in functions and constants.

- **Pixel formats** — Mono / Bayer / RGB / BGR / RGBa / BGRa / YUV at
  8 / 10 / 12 / 14 / 16 bits, packed and unpacked variants. Returns
  typed `Matrix{Gray{N0fX}}` / `Matrix{RGB{N0fX}}` / etc., compatible
  with the JuliaImages ecosystem.

- **High-level Camera API** — both `cam.Width = 640` property syntax and
  explicit `set_feature!(cam, :Width, 640)` calls. Tab-completion for
  the camera's full feature set in the REPL. Predicates
  (`<pIsAvailable>` etc.) are honoured automatically — features whose
  hardware isn't present raise `FeatureNotAvailable` instead of timing
  out.

- **Streaming** — background-task-based continuous acquisition with
  configurable backpressure (`DROP_OLDEST` / `DROP_NEWEST` / `BLOCK`)
  and live `frames_grabbed` / `frames_dropped` counters. Works as a
  do-block (`stream(cam) do ch ... end`) or with explicit
  `start_stream` / `stop_stream`.

- **Chunks** — per-frame metadata. Supports both the canonical
  `<ChunkID>` mechanism via `DSGetBufferChunkData` and the
  producer-virtual port mechanism (mvBlueFOX-style).

- **Events** — `EVENT_FEATURE_INVALIDATE` / `EVENT_FEATURE_CHANGE`
  listeners with graceful no-op when the producer doesn't support
  them.

- **Hot-plug detection** — `list_all_cameras` walks every installed
  producer; `watch_devices` / `watch_all_producers` emit `:added` /
  `:removed` events on a polling channel.

- **SFNC convenience helpers** — `set_aoi!`, `set_trigger!`,
  `set_exposure!`, `set_gain!`, plus `categories` /
  `features_in` / `features` for filtered listings.

- **Cross-platform** — Windows / Linux / macOS x64. CI matrix on all
  three. macOS framework-bundle producers picked up automatically.

## Verified hardware

End-to-end live-tested with:

- **MATRIX VISION mvBlueFOX3-1013C** (USB3 Vision color camera)
- via the **Balluff Impact Acquire** GenTL producer

Live numbers from a recent acceptance run:

| Metric | Result |
|---|---|
| Nodes parsed from camera XML | 1 184 |
| Features exposed | 654 |
| Full-feature read-walk success | **99.85 %** in 1.2 s |
| Mandatory SFNC features (Width/Height/PixelFormat/PayloadSize/AcquisitionMode/Start/Stop) | all read & written |
| Pixel formats decoded live | Mono8, Mono10, Mono12, BayerRG8, BayerRG10, RGB10p32 |
| Streaming throughput | 12.6 fps at 320×240 Mono8 (limited by camera default exposure) |

## Documentation

Full docs at <https://schrpe.github.io/GenICam.jl> covering:

- Quickstart walkthrough
- Feature access patterns (categories, selectors, visibility, predicates)
- Pixel-format reference
- Streaming with backpressure
- Chunks and events
- Hot-plug detection
- Vendor quirks (MATRIX VISION, Balluff, ...)
- Auto-generated API reference

## Architecture

```
GenICam (top-level)
│
├── GenTL ─────────────  Pure-Julia binding to GenTL_v1_5.h
├── GenApi ────────────  Camera XML → Node graph + SwissKnife evaluator
├── PixelFormats ──────  PFNC decoders → typed Matrices
├── Camera             ─ High-level cam.Feature = value
├── streaming.jl       ─ start_stream / stream do
├── chunks.jl          ─ per-frame metadata
├── events.jl          ─ feature listener pumps
├── sfnc.jl            ─ set_aoi! / set_trigger! / set_exposure! / ...
└── hotplug.jl         ─ list_all_cameras / watch_devices
```

See [docs/src/index.md](docs/src/index.md) for a deeper architecture
overview.

## Installation

Once registered:

```julia
using Pkg; Pkg.add("GenICam")
```

Until then:

```julia
using Pkg; Pkg.add(url = "https://github.com/schrpe/GenICam.jl")
```

A GenTL producer (`.cti` file) must be installed separately — get one
from your camera vendor's SDK. The package picks it up via the
`GENICAM_GENTL64_PATH` environment variable, which every major vendor's
installer sets automatically.

## License

MIT.
