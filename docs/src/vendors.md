```@meta
CurrentModule = GenICam
```

# Vendor notes

Real-world cameras and producers don't always match the spec letter-
for-letter. This page collects the deviations we've actually
encountered, the workaround in `GenICam.jl`, and a pointer to the
upstream reference (where applicable).

The package is verified against:

  * **Balluff Impact Acquire** producer (`mvGenTLProducer.cti` and the
    PCIe variant) on Windows.
  * **MATRIX VISION mvBlueFOX3-1013C** USB3 Vision camera.

CI runs unit tests on Linux / macOS but those runners don't have
producers installed; live-camera assertions self-skip via the
`isempty(list_producers())` guard in `runtests.jl`.

## MATRIX VISION mvBlueFOX3 (Balluff producer)

### Chunks: producer-virtual port instead of `<ChunkID>`

The mvBlueFOX3 XML declares ~16 `Chunk*` features
(`ChunkTimestamp`, `ChunkLineStatusAll`, `ChunkExposureTime`, ...) but
only **one** `<ChunkID>` element appears in the entire 936 KB XML.
Instead each chunk feature's backing register lives on a producer-
managed virtual port (`ImageInfoPort`), and reading the feature
through the GenApi nodemap returns the latest buffer's metadata. The
producer routes the underlying register read to the buffer
internally.

**Workaround:** [`enable_chunks!`](@ref) detects this case and
registers a "producer-virtual" binding (`chunk_id == 0`).
[`decode_chunks!`](@ref) clears the binding's cache and re-reads via
[`get_feature`](@ref) — bypassing `DSGetBufferChunkData` entirely.
Implemented in [src/chunks.jl](https://github.com/schrpe/GenICam.jl/blob/main/src/chunks.jl).

### `ChunkSelector` is a literal-only IntegerNode

The XML names `ChunkSelector` an `<Enumeration>`, but its `<pValue>`
points at an `<Integer>` (`ENB`) with `<Value>0</Value>` and no
`<pValue>`. In other words: the camera supports exactly one selector
choice (`Image`) and the literal Integer enforces it. Trying to set
the selector to anything else is a semantic error.

**Workaround:** writes that hit a literal-only `IntegerNode` are
treated as a no-op when the value matches, an `ArgumentError`
otherwise. `enable_chunks!` swallows the selector failure and
registers the binding anyway — the chunk is still readable through
the producer-virtual path. Implemented in
[src/GenApi/access.jl](https://github.com/schrpe/GenICam.jl/blob/main/src/GenApi/access.jl)
(`_check_literal_match!`).

### `TriggerSelector` follows the same literal-only pattern

`TriggerSelector` exposes 16 `EnumEntry` values
(`FrameStart`, `AcquisitionStart`, ... `FrameBurstStart`) but its
`<pValue>` is again a literal Integer (`XEB`) fixed at 0 — meaning
only `FrameStart` is supported. The same workaround applies:
[`set_trigger!`](@ref) silently no-ops the selector write when the
value matches.

### `EVENT_FEATURE_INVALIDATE` / `EVENT_FEATURE_CHANGE` not supported

Neither event type is implemented by the Balluff producer for this
camera — `GCRegisterEvent` returns `GC_ERR_NOT_IMPLEMENTED`.
[`on_feature_invalidate`](@ref) / [`on_feature_change`](@ref) catch
that error, log a single `@warn`, and return a no-op
[`ListenerHandle`](@ref) so user code stays portable.

### Per-frame chunk values can be stale

Because chunks come via the producer-virtual port and the producer
only updates them when a new buffer is delivered, repeated reads of
the same chunk between two grabs return the same value. This is
*correct* — the chunk reflects the most-recently delivered buffer's
metadata — but if your buffer pool starves the camera, the chunk
appears not to update. Make sure the streaming consumer keeps up.

### `<FormulaTo>` / `<FormulaFrom>` use `TO` in both directions

The GenApi spec says `<FormulaFrom>` should reference the input via
the variable `FROM`. Some MATRIX VISION cameras use `TO` in both
formulas regardless of direction. We *bind both names* to the input
value in the converter eval context — formulas work either way
without us second-guessing the spec text. See
[src/GenApi/access.jl](https://github.com/schrpe/GenICam.jl/blob/main/src/GenApi/access.jl)
(`_converter_context`).

### `ChunkPixelFormat` Enumeration entries are incomplete

The camera reports a chunk pixel-format raw value
(e.g. `0x6D4F484E`) that doesn't appear in the `<EnumEntry>` list
declared in the XML. Reading `cam.ChunkPixelFormat` therefore raises a
`KeyError`. This is a single `EnumerationNode` failure; everything
else on the camera works. Read it as `ChunkPixelFormatRaw` if you
need the numeric code.

## Producer interactions / quirks

### Single `EVENT_NEW_BUFFER` per data stream

The producer rejects a second `GCRegisterEvent(EVENT_NEW_BUFFER)` on a
data stream that already has one registered. This means the
single-frame [`grab`](@ref) and continuous [`stream`](@ref) cannot
both have an [`Acquisition`](@ref) live at the same time — they share
the data stream.

**Workaround:** [`start_stream`](@ref) automatically tears down the
single-frame buffer pool created by `grab` before standing up its own.
You don't have to think about it.

### Camera enters "error state" after I/O timeouts on absent hardware

Reading registers for hardware that isn't physically attached
(`mvLiquidLensStatus` etc.) provokes ~10 s I/O timeouts in the
producer. After several such timeouts the camera enters a state where
*every* subsequent register read fails immediately with
`GC_ERR_IO`. Recovery requires re-opening the camera (or, in extreme
cases, physically reconnecting the USB/Ethernet cable).

**Workaround:** before any read or write, the access layer evaluates
the node's `<pIsAvailable>` / `<pIsImplemented>` predicates and
raises [`GenApi.FeatureNotAvailable`](@ref) when one is false — so we
never even try to read absent-hardware registers. This is what bumped
the full-feature-walk success rate from 58% (with timeouts cascading
into a wedged camera) to 99.85%.

### Camera disappears from the bus after multiple kill-cycles

Repeatedly killing a Julia process mid-acquisition (Ctrl-C, force-
killing a hung test) eventually leaves the USB3 device in a state
where the producer can't see it anymore. `list_cameras` returns
empty until the camera is physically reconnected or the host's USB
host-controller is reset.

**Workaround:** none from our side — this is hardware-level. Just
let `close(cam)` run cleanly when possible.

## Reporting new quirks

If you hit a vendor / camera combination that requires special
handling, please open an issue with:

  * The camera vendor + model + firmware version.
  * The producer name + version (`producer_info(p, TL_INFO_VERSION)`).
  * The XML of the offending node (extract via
    `GenApi.load_xml(cam.port, cam.api)` and grep around the relevant
    feature name).
  * A minimal Julia snippet that reproduces the issue.
