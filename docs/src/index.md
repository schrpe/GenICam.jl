```@meta
CurrentModule = GenICam
```

# GenICam.jl

Pure-Julia implementation of the EMVA **GenICam** standard family —
device discovery, configuration, image acquisition, and per-frame
metadata for any vendor's machine-vision camera that ships a GenTL
producer DLL.

| | |
|---|---|
| **Standard** | GenTL 1.5, GenApi 1.1, SFNC, PFNC |
| **Platforms** | Windows x64, Linux x64, macOS x64 |
| **Julia** | 1.12+ |
| **License** | MIT |

## What is GenICam?

GenICam is the open standard for industrial camera control, maintained
by the EMVA. It defines four pieces that fit together at runtime:

  * **GenTL** — a C ABI exposed by vendor-supplied `.cti` "producer"
    DLLs. Handles device enumeration, register I/O, and image transport.
  * **GenApi** — an XML node-map embedded in each camera that describes
    the camera's features (Width, ExposureTime, Gain, ...) and how each
    one maps to a register or a computed expression.
  * **SFNC** (Standard Features Naming Convention) — a vocabulary so
    every vendor exposes "Width", "ExposureTime", "TriggerMode" with
    the same names and units.
  * **PFNC** (Pixel Format Naming Convention) — a numeric registry of
    pixel-format codes that buffers carry in their metadata.

`GenICam.jl` reimplements the consumer side of all four in pure Julia —
no GenApi C++ runtime, no vendor SDK linkage. Any producer that follows
the GenTL ABI works.

For a deeper introduction to the standard's vocabulary
(producers, handles, the node-map, formula evaluator, the
acquisition lifecycle) see **[Concepts](concepts.md)**.

## Quick example

```julia
using GenICam, GenICam.GenTL

# Find a vendor producer DLL via $GENICAM_GENTL64_PATH and load it.
api = load_producer(first(list_producers()))
producer = Producer(api)

# Pick the first visible camera, open it.
info = first(list_cameras(producer))
cam = open_camera(producer, info.interface, info.device)

# Configure: set AOI, pixel format, exposure.
set_aoi!(cam; width = 640, height = 480)
cam.PixelFormat = "Mono8"
set_exposure!(cam, 5000.0)        # 5 ms

# Grab one frame as a typed Julia matrix.
frame = grab(cam)
@show size(frame.image) eltype(frame.image) frame.pixel_format

close(cam); close(producer); close(api)
```

For continuous acquisition use the streaming API:

```julia
stream(cam) do channel
    for img in Iterators.take(channel, 100)
        process(img.image)
    end
end
```

## Architecture

```
GenICam (top-level package)
│
├── GenTL ─────────────  Pure-Julia binding to GenTL_v1_5.h
│   ├── ProducerAPI      (.cti loaded via Libdl + dlsym)
│   ├── Producer         TL_HANDLE + lifecycle
│   ├── Interface        IF_HANDLE
│   ├── Device           DEV_HANDLE
│   ├── DataStream       DS_HANDLE
│   └── Acquisition      buffer pool + EVENT_NEW_BUFFER loop
│
├── GenApi ────────────  Camera XML → Node graph
│   ├── 15 concrete node types
│   ├── 3-pass parser    (forward refs, invalidator wiring, formula compile)
│   ├── SwissKnife       full Pratt-parsed expression evaluator
│   ├── Cache + invalidators
│   └── Streamable save/load
│
├── PixelFormats ──────  PFNC decoders → typed Matrices
│   └── Mono / Bayer / RGB / BGR / RGBa / BGRa / YUV at 8 / 10 / 12 / 14 / 16 bits
│
├── Camera (top-level)   High-level API: `cam.Width = 640`, `grab(cam)`
├── streaming.jl         `start_stream` / `stream do`
├── chunks.jl            per-frame metadata
├── events.jl            feature-invalidate / feature-change listeners
├── sfnc.jl              `set_aoi!` / `set_trigger!` / `set_exposure!` / ...
└── hotplug.jl           `list_all_cameras` / `watch_devices`
```

## Status

| Area | Status |
|---|---|
| GenTL consumer (full `GenTL_v1_5.h` surface) | live-tested |
| GenApi node-map (15 node types, all SwissKnife operators) | 99.85% feature read on a real camera |
| 7 SFNC mandatories | live-tested |
| Pixel formats (Mono/Bayer/RGB/BGR/YUV) | unit-tested + live-tested |
| Streaming with backpressure | live-tested |
| Chunks (canonical + producer-virtual) | live-tested |
| Feature events (with graceful degradation) | API live-tested |
| Hot-plug detection | live-tested |
| Cross-platform (Windows / Linux / macOS) | Windows live, Linux/macOS via CI |
| Documentation | this site |

## Documentation map

**Background — what is GenICam?**

  * **[Concepts](concepts.md)** — the four GenICam pieces explained
    (Producer/Consumer model, GenTL handle hierarchy, GenApi node-map,
    SFNC, PFNC, full acquisition lifecycle).
  * **[The SwissKnife formula language](swissknife.md)** — operator
    precedence, built-in functions, `FROM` / `TO` convention, real
    examples from camera XMLs.

**Practical guides**

  * **[Quickstart](quickstart.md)** — installation, environment setup, first grab.
  * **[Features](features.md)** — `cam.X` syntax, SFNC mandatories, categories, selectors, visibility, predicates, caching.
  * **[Pixel formats](pixelformats.md)** — supported codes, return types, PFNC bit-layout, Bayer policy.
  * **[Streaming](streaming.md)** — continuous acquisition, drop policies, statistics.
  * **[Chunks and events](chunks_events.md)** — per-frame metadata, feature listeners.
  * **[Hot-plug detection](hotplug.md)** — multi-producer enumeration, device-watch channels.

**Reference**

  * **[Vendor notes](vendors.md)** — known camera quirks (MATRIX VISION, Balluff, ...).
  * **[API reference](api.md)** — every exported name with full signature.

## Comparison with other GenICam libraries

| | GenICam.jl | Aravis (GLib/C) | Harvesters (Python) | Pylon (Basler-only) |
|---|---|---|---|---|
| Language | pure Julia | C | Python (binds GenApi C++) | C++ / .NET wrapper |
| GenApi | own pure-Julia parser + evaluator | own pure-C reimplementation | binds the EMVA reference C++ | Basler's vendor lock |
| Vendor DLL needed | `.cti` producer (any vendor) | producer not used (Aravis is itself a producer) | `.cti` producer | Basler-only |
| Cross-platform | Windows / Linux / macOS | Linux / Windows | Windows / Linux | Windows / Linux |

```@docs
GenICam
```
