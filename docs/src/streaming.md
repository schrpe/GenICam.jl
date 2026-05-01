```@meta
CurrentModule = GenICam
```

# Streaming

[`grab`](@ref) does single-frame acquisition: configure → trigger →
wait → return. For live preview, frame-rate measurement, or any
longer-running session, use the **streaming** API: a background `Task`
that pushes decoded frames into a `Channel` as the camera produces
them.

## Two entry points

```julia
# do-block — recommended for scoped use
stream(cam) do channel
    for frame in Iterators.take(channel, 100)
        process(frame.image)
    end
end
# stop_stream is called automatically on exit (success or exception)

# explicit — when the stream needs to outlive a single block
sh = start_stream(cam; num_buffers = 8)
for _ in 1:100
    frame = take!(sh.channel)
    process(frame.image)
end
stop_stream(cam)
```

[`stream`](@ref) without a `do` returns the channel directly; you're
responsible for [`stop_stream`](@ref).

## Configuration

```julia
start_stream(cam;
    num_buffers   = 8,             # producer-side buffer pool size
    decode        = true,           # push DecodedFrame (true) or Vector{UInt8} (false)
    channel_size  = 4,              # Julia Channel capacity
    policy        = DROP_OLDEST,    # what to do when channel is full
    timeout_ms    = 1000,           # per-frame fetch timeout
)
```

  * **`num_buffers`** — how many image buffers the producer can fill
    ahead of the consumer. Larger values absorb consumer hiccups
    without dropping frames; the cost is RAM (each buffer is full
    payload-size).
  * **`decode`** — when `true` (default) each frame is run through the
    pixel-format decoder and the channel yields
    [`DecodedFrame`](@ref) values. When `false`, raw producer bytes are
    *copied* into a fresh `Vector{UInt8}` and pushed; useful when you
    want to ship bytes elsewhere (network, file) without paying for a
    decode you'll throw away.
  * **`channel_size`** — controls how many frames sit between producer
    and consumer. Combined with `policy` it determines what happens
    when consumer is slower.

## Backpressure policies

| Policy | When channel is full | Best for |
|---|---|---|
| `DROP_OLDEST` (default) | drop the oldest queued frame, push the new one | live preview — freshness matters more than completeness |
| `DROP_NEWEST`           | discard the newly arrived frame                | rate-limited storage where order matters |
| `BLOCK`                 | block the producer task until consumer drains  | offline analysis where every frame must be kept |

`DROP_OLDEST` and `DROP_NEWEST` increment [`frames_dropped`](@ref) when
they drop. `BLOCK` will eventually stall the camera (the producer's
buffer pool fills up); use only when you must not lose frames and your
consumer can keep up *on average*.

## Statistics

```julia
sh = start_stream(cam)
# ... consumer loop ...
stop_stream(cam)

frames_grabbed(cam)       # how many frames actually ended up on the channel
frames_dropped(cam)       # how many were dropped due to backpressure (or decode failure)
is_streaming(cam)          # true while the stream task is alive
```

The counters survive `stop_stream` — call them after the stream ends to
see the final tally. Starting a new stream resets them (each
[`start_stream`](@ref) creates a fresh [`StreamHandle`](@ref)).

## Lifecycle and cleanup

A few invariants worth knowing:

  * Only **one** stream may be active per camera at a time —
    `start_stream` throws if another is running.
  * If you've used `grab` before streaming, the single-frame buffer
    pool is torn down automatically when `start_stream` runs (only one
    `EVENT_NEW_BUFFER` registration is allowed per data stream).
  * `close(cam)` calls `stop_stream` first — the camera object is the
    canonical owner.
  * The streaming task always re-queues each buffer to the producer
    *before* pushing to the channel, so the producer never starves
    waiting for a buffer the consumer hasn't drained yet.

## GC safety

When `decode = true` the decoder allocates a fresh image, so the
channel value owns its memory. Safe.

When `decode = false` the streaming task copies the producer's bytes
into a fresh `Vector{UInt8}` before pushing. Also safe — but if you're
tempted to skip the copy (for performance), don't: the underlying
producer buffer is re-queued immediately and the next frame overwrites
it. The copy is essential.

## Example: rolling FPS

```julia
function fps_for(cam, seconds = 5.0)
    t0 = time()
    n = 0
    stream(cam; num_buffers = 8) do channel
        while time() - t0 < seconds
            isready(channel) || (sleep(0.01); continue)
            take!(channel)
            n += 1
        end
    end
    return n / (time() - t0)
end

set_aoi!(cam; width = 640, height = 480)
cam.PixelFormat = "Mono8"
@info "achieved fps" fps = fps_for(cam, 5)
```

## Example: ring buffer

```julia
using GenICam

mutable struct Ring{T}
    buf::Vector{T}
    pos::Int
    n::Int
end
Ring{T}(cap::Int) where {T} = Ring{T}(Vector{T}(undef, cap), 0, 0)
function push_!(r::Ring{T}, x::T) where {T}
    r.pos = mod1(r.pos + 1, length(r.buf))
    r.buf[r.pos] = x
    r.n += 1
end

ring = Ring{Any}(60)        # last 60 frames
sh = start_stream(cam)
@async begin
    for frame in sh.channel
        push_!(ring, frame)
    end
end

# ... main thread does whatever ...

# At any point you can inspect the most-recent N frames:
last_frames = [ring.buf[mod1(ring.pos - i, length(ring.buf))] for i in 0:9]
stop_stream(cam)
```

The `BLOCK` policy is preferable here because we *never* want to drop
frames into a ring buffer (drops would silently produce gaps). With
`DROP_OLDEST` you'd see decreasing fidelity if the consumer ever
stalls.

See [API reference](api.md) for full signatures of `stream`,
`start_stream`, `stop_stream`, `is_streaming`, `frames_grabbed`,
`frames_dropped`, `StreamPolicy`, and `StreamHandle`.
