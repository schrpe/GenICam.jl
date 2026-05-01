```@meta
CurrentModule = GenICam
```

# Background: the GenICam standard family

This page explains the *concepts* `GenICam.jl` builds on — enough to
make sense of the rest of the documentation. It's deliberately filtered
to what matters for using this library; the full EMVA specifications
(GenTL 1.5, GenApi 1.1, SFNC 2.7, PFNC 2.4) are 200+ PDF pages each.

## Why GenICam exists

Industrial cameras predate USB cameras by decades. By the early 2000s
every vendor had their own SDK, their own register map, their own way
of saying "set the exposure time". Mixing two cameras in one
application meant mixing two SDKs.

The European Machine Vision Association (EMVA) hammered this out into a
four-piece standard so that any camera and any application can talk to
each other:

  * **GenTL** — a stable C ABI for transport-layer access (USB3 Vision,
    GigE Vision, Camera Link, CoaXPress, ...). Vendors ship a "GenTL
    producer" DLL; applications are "GenTL consumers". The producer
    knows the wire protocol; the consumer doesn't have to.
  * **GenApi** — an XML node-map embedded in every camera that
    describes its features (`Width`, `ExposureTime`, `TriggerMode`, ...)
    and how each maps to a register or a computed expression.
  * **SFNC** — the Standard Features Naming Convention. So every
    vendor's camera exposes "Width" with the same name, the same units,
    the same semantics.
  * **PFNC** — the Pixel Format Naming Convention. A registry of
    32-bit codes that buffers carry to identify their pixel layout.

`GenICam.jl` is a pure-Julia consumer of all four pieces. You bring a
producer DLL (any vendor); the package handles the rest.

## Producer and consumer

```
┌──────────────────────────────────────────────────────────┐
│                                                          │
│   Application                                            │
│   ┌──────────────────────┐                               │
│   │  your Julia code     │                               │
│   └──────────┬───────────┘                               │
│              │ uses                                       │
│   ┌──────────▼───────────┐                               │
│   │   GenICam.jl         │  ← consumer                   │
│   │  (this package)      │                               │
│   └──────────┬───────────┘                               │
│              │ ccall via Libdl                            │
└──────────────┼──────────────────────────────────────────┘
               │
┌──────────────▼──────────────────────────────────────────┐
│   Vendor producer DLL  (.cti file)                      │
│   ┌────────────────────────────────────────┐             │
│   │  Implements the GenTL_v1_5.h ABI       │  ← producer │
│   │  Knows the wire protocol               │             │
│   └────────────────────────────────────────┘             │
└──────────────┬──────────────────────────────────────────┘
               │
               │ wire protocol (GigE Vision / U3V / CXP / ...)
               ▼
       ┌─────────────────┐
       │     Camera      │
       └─────────────────┘
```

The producer is a regular shared library (`.dll` / `.so` / `.dylib`)
renamed to `.cti` by convention. `GenICam.jl` `dlopen`s it and resolves
its exported symbols (`GCInitLib`, `TLOpen`, `IFOpenDevice`, ...) via
`Libdl.dlsym` into a function-pointer table — every subsequent `ccall`
goes through that table.

You don't pick *which* producer at compile time. You can load multiple
producers in one Julia process — `list_all_cameras()` does exactly
that and returns devices tagged with the producer that found them.

## Handle hierarchy

GenTL is a handle-based C API. Every operation takes an opaque pointer
("handle") that names some module of the producer. The handles nest:

```
ProducerAPI                  (one per .cti — the dlopen handle + symbol table)
  │
  ▼
Producer / TL_HANDLE         (the "Transport Layer" — TLOpen result)
  │
  ▼
Interface / IF_HANDLE        (one per detected bus / NIC / PCIe slot)
  │
  ▼
Device / DEV_HANDLE          (one per connected camera)
  │  ├─ Port / PORT_HANDLE   (the camera's register map; DevGetPort)
  │  └─ Remote Device        (alias for the camera-side feature space)
  │
  ▼
DataStream / DS_HANDLE       (an image-stream channel — usually one per camera)
  │
  ▼
Buffer / BUFFER_HANDLE       (one per announced image buffer in the pool)
  │
  ▼
Event / EVENT_HANDLE         (registered notifications — new-buffer, feature-change, ...)
```

Each level knows its parent (`IFGetParentTL`, `DevGetParentIF`,
`DSGetParentDev`) so you can walk back up. `GenICam.jl` represents
each as a Julia struct that owns its handle and runs the matching
close on `Base.close` or finalisation:
`GenTL.Producer`, `GenTL.Interface`, `GenTL.Device`,
`GenTL.DataStream`, `GenTL.Acquisition`.

## GenTL ABI conventions

The whole API is built on a few patterns worth knowing.

### Error codes

Every function returns `GC_ERROR` (`Int32`). `0` (`GC_ERR_SUCCESS`)
means success; everything else is a failure code (`GC_ERR_TIMEOUT`,
`GC_ERR_INVALID_HANDLE`, `GC_ERR_NOT_AVAILABLE`, ...). The full list is
in `GenTL_v1_5.h` and mirrored as Julia constants in
[GenTL.types.jl](https://github.com/schrpe/GenICam.jl/blob/main/src/GenTL/types.jl).

After a non-zero return you can call `GCGetLastError` for a
human-readable message. `GenICam.jl` does this automatically and wraps
every error in a `GenTL.GenTLError` exception with both the numeric
code and the producer's last-error string.

### Two-pass size-query pattern

Functions that return strings or variable-length data take a
`size_t *piSize` argument. Callers invoke them twice:

  1. With `pBuffer = NULL` and `*piSize = 0` to query the required size.
  2. With a buffer of the returned size to actually fetch the data.

The Julia wrappers hide this; you call e.g.
`GenTL.tl_get_info_string` and get the string back.

### Modules and "info" commands

Most module types (`TL`, `IF`, `Device`, `DataStream`, `Buffer`, `Port`)
have a `*GetInfo` function plus an enum of `INFO_CMD` values:

```julia
producer_info(p, TL_INFO_VENDOR)        # "Balluff"
producer_info(p, TL_INFO_MODEL)         # "Balluff GenTL Producer..."
device_info(d, DEVICE_INFO_VENDOR)      # "MATRIX VISION GmbH"
device_info(d, DEVICE_INFO_MODEL)       # "mvBlueFOX3-1013C"
ds_get_info(api, ds, STREAM_INFO_PAYLOAD_SIZE, Csize_t)   # 614400
```

This is the standard introspection mechanism — there's no
`getDeviceVendor()` function, just `IFGetDeviceInfo(...,
DEVICE_INFO_VENDOR, ...)`.

### Buffer model

Image buffers in GenTL are *consumer-allocated*. The flow:

  1. Consumer (`GenICam.jl`) allocates `N` Julia `Vector{UInt8}` of the
     payload size.
  2. For each buffer: `DSAnnounceBuffer(ds, ptr, size, private, &handle)`
     — the producer now knows about this memory region.
  3. `DSQueueBuffer(ds, handle)` — the buffer is now in the producer's
     "input pool" waiting to be filled.
  4. `DSStartAcquisition(ds, ...)` — the producer begins filling
     buffers.
  5. The consumer registers an `EVENT_NEW_BUFFER` event and polls
     `EventGetData` to learn when each buffer is full.
  6. Consumer reads the data, calls `DSQueueBuffer` again to recycle.
  7. On stop: `DSStopAcquisition` then `DSRevokeBuffer` for each.

The fact that the consumer owns the memory is what makes pure-Julia
acquisition possible — the producer writes pixels directly into our
`Vector{UInt8}` and we read them back as a typed matrix in Julia.

### Event model

Events are registered on a "source" handle (data stream, device, port,
...) and identified by an `EVENT_TYPE`:

```
EVENT_NEW_BUFFER          — new image filled (per data stream)
EVENT_FEATURE_INVALIDATE  — camera says a feature value is now stale
EVENT_FEATURE_CHANGE      — camera pushes a new feature value
EVENT_REMOTE_DEVICE       — generic remote-device event
EVENT_ERROR               — module-level error notification
```

`GCRegisterEvent` returns an `EVENT_HANDLE`; `EventGetData(h, ..., timeout)`
blocks for the next event of that type. `GenICam.jl` wraps these:

  * Buffer events: handled internally by `GenTL.Acquisition`.
  * Feature events: exposed via [`on_feature_invalidate`](@ref) and
    [`on_feature_change`](@ref) with graceful no-op for producers
    that don't support them.

## GenApi node-map

The producer exposes the camera through `DevGetPort` — a port-handle
into the camera's register space. Through that port, two things flow:

  * **Register reads/writes** — bytes addressed by 64-bit offsets.
  * **A bundled XML document** — the camera's GenApi node-map,
    typically ZIP-compressed and 200–1000 KB.

`GenICam.jl` downloads the XML on `open_camera` and parses it into a
graph of nodes:

```
RegisterDescription (root)
│
├── <Category Name="Root">
│   ├── <pFeature>DeviceControl</pFeature>
│   ├── <pFeature>ImageFormatControl</pFeature>
│   └── <pFeature>AcquisitionControl</pFeature>
│
├── <Category Name="ImageFormatControl">
│   ├── <pFeature>Width</pFeature>
│   ├── <pFeature>Height</pFeature>
│   └── <pFeature>PixelFormat</pFeature>
│
├── <Integer Name="Width">         ← user-facing feature
│   ├── <pValue>WidthReg</pValue>   ← reference to the backing register
│   ├── <Min>1</Min>
│   └── <Max>1920</Max>
│
├── <IntReg Name="WidthReg">         ← the actual register
│   ├── <Address>0xA004</Address>
│   ├── <Length>4</Length>
│   ├── <Sign>Unsigned</Sign>
│   └── <Endianess>LittleEndian</Endianess>
│
├── <Enumeration Name="PixelFormat">
│   ├── <pValue>PixelFormatReg</pValue>
│   ├── <EnumEntry Name="Mono8"><Value>0x01080001</Value></EnumEntry>
│   └── <EnumEntry Name="BayerRG8"><Value>0x01080009</Value></EnumEntry>
│
├── <Command Name="AcquisitionStart">
│   ├── <pValue>AcquisitionStartReg</pValue>
│   └── <CommandValue>1</CommandValue>
│
├── <SwissKnife Name="MaxBufferCount">
│   ├── <pVariable Name="ImgSize">PayloadSize</pVariable>
│   └── <Formula>(64*1024*1024) / ImgSize</Formula>
│
└── <Converter Name="ExposureTime">     ← bidirectional formula
    ├── <pValue>ExposureTimeReg</pValue>
    ├── <FormulaTo>TO * 100</FormulaTo>     ← microseconds → ticks
    └── <FormulaFrom>FROM / 100</FormulaFrom> ← ticks → microseconds
```

### Reference types

GenApi nodes form a directed graph through reference elements. The
ones `GenICam.jl` understands:

| Element | Direction | Meaning |
|---|---|---|
| `<pValue>X</pValue>` | this node → X | "my value lives in node X" (chain to backing register) |
| `<pAddress>X</pAddress>` | this node → X | "add X's current value to my register address" |
| `<pIndex Offset="N">X</pIndex>` | this node → X | "add X's current value × N to my register address" |
| `<pInvalidator>X</pInvalidator>` | X → this node | "when X is written, my cached value is stale" |
| `<pSelected>X</pSelected>` | this node → X | "I am a selector that gates X (e.g. GainSelector → Gain)" |
| `<pVariable Name="A">X</pVariable>` | this node → X | inside a SwissKnife/Converter formula, the symbol `A` reads X |
| `<pIsAvailable>X</pIsAvailable>` | this node → X | runtime predicate: I'm only usable when X is truthy |
| `<pIsImplemented>X</pIsImplemented>` | this node → X | hardware-presence predicate |
| `<pIsLocked>X</pIsLocked>` | this node → X | "my value is currently locked" predicate |

References are *names*, not direct pointers. The parser resolves them
in pass 2 — see `GenApi.parse_nodemap` for the three-pass scheme
(construct → bind → compile-formulas).

### Caching and invalidation

Each node has a `<Cacheable>` policy:

  * `NoCache` — always re-read from the device.
  * `WriteThrough` — cache reads; cache writes too (assume device
    accepts the value verbatim).
  * `WriteAround` — cache reads; invalidate on write (re-read next time
    to discover the device's actual value).
  * (default) — cache reads; invalidate on write.

`<pInvalidator>` declarations build a reverse map at parse time: when
node `X` is written, every node that listed `X` as an invalidator gets
its cache cleared. Same for `<pSelected>` declarations on selectors —
writing the selector invalidates everything it selects.

After an explicit `set_feature!`, `GenICam.jl` currently wipes the
*entire* nodemap cache (pessimistic but always correct — see
[`features.md`](features.md#caching) for the rationale).

## SFNC: standard feature names

The Standard Features Naming Convention is the agreement that every
SFNC-compliant camera exposes certain feature *names* with certain
semantics. The mandatory ones for a 2D area-scan camera:

| Name | Type | Meaning |
|---|---|---|
| `Width` | Integer | image width in pixels |
| `Height` | Integer | image height in pixels |
| `PixelFormat` | Enumeration | output pixel layout (uses PFNC codes) |
| `PayloadSize` | Integer (RO) | bytes per frame the camera will deliver |
| `AcquisitionMode` | Enumeration | `SingleFrame` / `MultiFrame` / `Continuous` |
| `AcquisitionStart` | Command | begin acquiring |
| `AcquisitionStop` | Command | stop acquiring |

These seven are sufficient to grab a frame. SFNC also defines a much
larger set of *recommended* features grouped into categories
(`AcquisitionControl`, `AnalogControl`, `ImageFormatControl`,
`DigitalIOControl`, `DeviceControl`, `ChunkDataControl`, ...). Most of
them follow predictable patterns:

  * **Selector chains**: `TriggerSelector` (Enum) chooses *which*
    trigger; `TriggerMode` / `TriggerSource` / `TriggerActivation`
    apply to whichever was selected. Same pattern for `GainSelector`,
    `ExposureTimeSelector`, `LineSelector`, etc.
  * **Auto/Manual pairs**: `ExposureAuto` (`Off`/`Once`/`Continuous`)
    sits next to `ExposureTime`; setting Auto disables manual control.
  * **`*Raw` legacy fallbacks**: older cameras exposed
    `ExposureTimeRaw` (Integer, ticks) instead of `ExposureTime`
    (Float, µs). The [`set_exposure!`](@ref) helper falls back
    gracefully.

## PFNC: pixel-format codes

The Pixel Format Naming Convention assigns each format a 32-bit code
plus a symbolic name. The code's bit layout encodes structure:

```
bits 31..24   — Pixel layout marker
                  0x01 = single-component (mono / Bayer)
                  0x02 = multi-component  (RGB, BGR, RGBa, ...)
                  0x03 = multi-part       (3D / depth maps)

bits 23..16   — Effective bits-per-pixel
                  0x08 = 8-bit, 0x10 = 16-bit, 0x18 = 24-bit, 0x20 = 32-bit, 0x30 = 48-bit, ...

bits 15..0    — Format ID  (vendor-assigned within the layout/bpp class)
```

Examples decoded:

  * `0x01080001` = Mono8         (single-component, 8 bpp, ID 1)
  * `0x01080009` = BayerRG8      (single-component, 8 bpp, ID 9)
  * `0x01100007` = Mono16        (single-component, 16 bpp, ID 7)
  * `0x02180014` = RGB8          (multi-component, 24 bpp, ID 0x14)
  * `0x02300033` = RGB16         (multi-component, 48 bpp, ID 0x33)
  * `0x010C0006` = Mono12Packed  (single-component, 12 bpp, ID 6)
  * `0x0220001D` = RGB10p32      (multi-component, 32 bpp, ID 0x1D)

Each buffer the producer hands us carries its code in
`BUFFER_INFO_PIXELFORMAT` plus a *namespace* in
`BUFFER_INFO_PIXELFORMAT_NAMESPACE` (legacy `GEV` vs modern `PFNC_32BIT`
— same numeric code in either, vendor-dependent which they report).
`GenICam.jl` registers each format under both namespaces so the lookup
works either way.

The full format table is in [Pixel formats](pixelformats.md).

## Putting it all together: an acquisition lifecycle

Now we can trace what happens between `load_producer` and `grab(cam)`:

```
load_producer(path)
  └─ Libdl.dlopen(path)
  └─ Libdl.dlsym(handle, :GCInitLib), ... (resolve every symbol)
  └─ ccall GCInitLib                       ← producer global init
                                            (returns ProducerAPI)

Producer(api)
  └─ ccall TLOpen → TL_HANDLE                ← transport-layer module

list_cameras(producer)
  └─ ccall TLUpdateInterfaceList            ← refresh hardware list
  └─ for each interface:
       ccall TLOpenInterface → IF_HANDLE
       ccall IFUpdateDeviceList
       ccall IFGetDeviceID + IFGetDeviceInfo

open_camera(producer, ifinfo, devinfo)
  ├─ ccall TLOpenInterface → IF_HANDLE
  ├─ ccall IFOpenDevice    → DEV_HANDLE       ← exclusive control of one camera
  ├─ ccall DevOpenDataStream → DS_HANDLE      ← image-streaming channel
  ├─ ccall DevGetPort → PORT_HANDLE           ← register-map handle
  ├─ ccall GCGetPortURL                       ← URL of camera's XML
  │     "Local:cam.zip;0xA000;0x12340"
  ├─ ccall GCReadPort(port, 0xA000, 0x12340)  ← download the XML bytes
  ├─ ZipFile decompression
  ├─ EzXML parse
  ├─ GenApi parse_nodemap                     ← 3-pass: construct / bind / compile
  └─ return Camera

cam.Width = 640
  ├─ getproperty/setproperty! → set_feature!(cam, :Width, 640)
  ├─ Width is an Integer node → resolve pValue → WidthReg (IntReg)
  ├─ encode 640 as 4-byte little-endian unsigned
  └─ ccall GCWritePort(port, WidthReg.address, bytes)

grab(cam)
  ├─ Lazy-allocate Acquisition:
  │    ├─ N × Vector{UInt8}(undef, payload_size)
  │    ├─ ccall DSAnnounceBuffer × N         ← register each pointer
  │    ├─ ccall DSQueueBuffer × N            ← into input pool
  │    └─ ccall GCRegisterEvent(EVENT_NEW_BUFFER) → EVENT_HANDLE
  ├─ ccall DSStartAcquisition(ds, num_to_acquire = 1)
  ├─ execute_command!(:AcquisitionStart) → GCWritePort
  ├─ ccall EventGetData(event, &EVENT_NEW_BUFFER_DATA, timeout)  ← block
  ├─ Decode pixel format → typed Matrix
  ├─ ccall DSQueueBuffer (return buffer to pool)
  ├─ execute_command!(:AcquisitionStop) → GCWritePort
  ├─ ccall DSStopAcquisition (no-op if producer auto-stopped)
  └─ return DecodedFrame
```

That's it. Every operation in `GenICam.jl` is some composition of
those pieces.

## Further reading

  * The EMVA standard PDFs (free) at <https://www.emva.org>:
    * "GenICam Standard" — top-level GenApi spec
    * "GenICam Standard Features Naming Convention (SFNC)"
    * "GenICam GenTL Standard"
    * "GenICam Pixel Format Naming Convention (PFNC)"
  * The [official GenICam header
    `GenTL_v1_5.h`](https://www.emva.org/wp-content/uploads/GenICam_GenTL_1_5.pdf)
    — the C ABI this package binds.
  * [Aravis](https://aravisproject.github.io/aravis/) — a pure-C
    re-implementation that replaces both the consumer and the producer
    layers; readable reference for many GenApi semantics.
  * [Harvesters](https://github.com/genicam/harvesters) — Python
    consumer that binds the EMVA reference C++ implementation; useful
    for cross-checking behaviour.
