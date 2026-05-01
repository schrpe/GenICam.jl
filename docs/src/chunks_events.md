```@meta
CurrentModule = GenICam
```

# Chunks and events

Two related-but-distinct mechanisms for *out-of-band* camera state:

  * **Chunks** — per-frame metadata appended to (or interleaved with)
    each image. Things like the exposure time *at capture*, an
    incrementing FrameID, a hardware timestamp, the trigger source,
    the GPIO line state. Captured atomically with the frame.
  * **Events** — asynchronous notifications fired by the producer when
    the camera changes a feature on its own (auto-exposure ramping
    `ExposureTime`, etc.). Rare in practice but the GenTL standard
    defines them.

## Chunks

### Discovery

```julia
chunk_features(cam)
# Vector{Symbol} of every chunk-eligible node in the parsed nodemap.
# Includes both `<ChunkID>`-tagged nodes (canonical) and `Chunk*`-prefixed
# nodes that some vendors expose via a producer-virtual port.
```

The control nodes themselves (`ChunkModeActive`, `ChunkSelector`,
`ChunkEnable`) are intentionally excluded — those configure chunks,
they're not chunk values.

### Enabling

```julia
enable_chunks!(cam, [:ChunkTimestamp, :ChunkExposureTime, :ChunkLineStatusAll])
```

Internally this:

  1. Sets `ChunkModeActive = true` to put the camera in chunk mode.
  2. For each name, writes `ChunkSelector = "<bare name>"` then
     `ChunkEnable = true` to mark that chunk for inclusion.
  3. Resolves and caches a [`ChunkBinding`](@ref) per name so future
     [`decode_chunks!`](@ref) calls don't have to walk the nodemap.

Selector / Enable writes are *best-effort*: some cameras (mvBlueFOX
e.g.) only support a single `Image` selector and bundle every chunk
together. If a selector write fails, the binding is still registered
and the chunk is read directly through the nodemap when frames arrive.

### Reading

After `enable_chunks!`, every [`grab`](@ref) automatically populates
its [`Frame`](@ref)'s `chunks` field. The latest dict is also stashed
on the camera as [`last_chunks`](@ref):

```julia
img = grab(cam)
last_chunks(cam)
# Dict{Symbol, Any}(:ChunkTimestamp => 18530,
#                   :ChunkExposureTime => 1.33e6,
#                   :ChunkLineStatusAll => 0)
```

Stop chunks with [`disable_chunks!`](@ref) — turns off
`ChunkModeActive` and clears the binding cache.

### How the decoder finds chunk bytes

Two paths, picked per binding at parse time:

  * **Canonical** (`<ChunkID>` tagged): the producer reports the chunk
    layout via `DSGetBufferChunkData`, returning a list of
    `(chunk_id, offset, length)` triples for the current buffer. We
    match each triple to a binding's `chunk_id` and decode the bytes
    using the node type's codec (IntReg / FloatReg / StringReg /
    MaskedIntReg / Converter / ...).
  * **Producer-virtual** (no `<ChunkID>`, but the chunk feature lives
    on a vendor-private virtual port): the producer routes register
    reads on that port to the most recent buffer's metadata. We just
    re-read the feature value through the nodemap *after invalidating
    the cache* so each frame gets fresh data.

Most cameras use one mechanism or the other; some (mvBlueFOX3 + Balluff
producer combinations) use the second exclusively. `enable_chunks!`
registers bindings for both kinds; `decode_chunks!` picks the right
path per binding.

### Chunks during streaming

Chunks work transparently during [`stream`](@ref) when `decode = true`
— the streaming loop calls the same decode pipeline that `grab` uses,
so each `DecodedFrame` arrives with chunks already parsed and the
camera's `last_chunks` updated.

When `decode = false` (raw bytes path), the chunk fields aren't
populated automatically — call [`decode_chunks!`](@ref) on the raw
[`Frame`](@ref) yourself.

See [API reference](api.md) for full signatures of `chunk_features`,
`enable_chunks!`, `disable_chunks!`, `decode_chunks!`, `last_chunks`,
and `ChunkBinding`.

---

## Events

GenTL defines four event types; two of them (`EVENT_FEATURE_INVALIDATE`,
`EVENT_FEATURE_CHANGE`) are about camera-side feature changes that the
producer wants to push to the consumer. Many producers don't actually
fire these; this section assumes they do.

### Registering listeners

```julia
hd = on_feature_invalidate(cam) do event
    @info "camera invalidated" feature=event.name kind=event.kind
end
```

Or filter by name:

```julia
on_feature_change(cam, "ExposureTime") do event
    @info "exposure changed to" event.value
end
```

[`on_feature_invalidate`](@ref) and [`on_feature_change`](@ref) lazily
spawn a single background task per camera that loops over `EventGetData`
with a finite timeout. Multiple listeners share the same pump.

### Graceful degradation

Producers that don't support feature events return `GC_ERR_NOT_AVAILABLE`
or `GC_ERR_NOT_IMPLEMENTED` from `GCRegisterEvent`. The library catches
both, logs a single `@warn`, and returns a no-op
[`ListenerHandle`](@ref) (id 0). User code stays portable: a listener
that's never going to fire is silently ignored rather than turning into
a hard error.

```julia
hd = on_feature_invalidate(cam, callback)
# WARN: producer does not support EVENT_FEATURE_INVALIDATE
# hd === ListenerHandle(0)   — no-op handle
remove_listener(cam, hd)        # also no-op, but legal
```

### Unregistering

```julia
remove_listener(cam, hd)
```

Or close the entire pump (rarely needed; `close(cam)` does it):

```julia
close_event_pump!(cam)
```

### What gets dispatched

A [`FeatureEvent`](api.md) record carries `kind` (`:invalidate` or
`:change`), the feature `name`, an optional `value` (for `:change`
only), and the wall-clock receipt time.

For `:invalidate` events, the library *also* clears the matching
node's cache before firing the listener — so a listener that calls
`get_feature(cam, event.name)` re-reads from the device.

See [API reference](api.md) for full signatures of
`on_feature_invalidate`, `on_feature_change`, `remove_listener`, and
`close_event_pump!`.
