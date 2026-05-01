"""
Continuous acquisition / streaming API.

`grab` is single-frame: configure → trigger → wait → return. For live
preview, frame-rate measurement, or any longer-running acquisition,
streaming is the right tool. The API:

    sh = start_stream(cam)
    img = take!(sh.channel)              # block until next frame
    stop_stream(cam)

    # do-block variant — automatically tears down on exit
    stream(cam) do ch
        for img in Iterators.take(ch, 100)
            process(img)
        end
    end

Internally a background `Task` polls `next_frame_or_timeout` in a loop and
pushes either decoded `DecodedFrame`s (default) or raw `Frame`-data copies
(`decode = false`) into a `Channel`. Backpressure is configurable via
`policy`:

  * `DROP_OLDEST` (default) — when the consumer falls behind, drop the
    oldest queued frame to make room for the new one. Best for live
    preview where freshness matters more than completeness.
  * `DROP_NEWEST` — drop the new frame instead. Symmetric option.
  * `BLOCK` — block the producer task until the consumer drains. Causes
    the camera to stall once its buffer pool fills; use only when you
    must not lose frames.

`frames_grabbed(cam)` and `frames_dropped(cam)` give live counters.
"""

# ---------------------------------------------------------------------------
# Backpressure policy
# ---------------------------------------------------------------------------

"""
    StreamPolicy

How [`start_stream`](@ref) handles a full delivery channel:

  * `DROP_OLDEST` — drop the oldest queued frame to make room for the
    new one. Best for live preview where freshness matters more than
    completeness.
  * `DROP_NEWEST` — discard the newly arrived frame instead.
    Symmetric option.
  * `BLOCK` — block the producer task until the consumer drains. The
    camera stalls once its buffer pool fills; use only when frames
    must not be lost.
"""
@enum StreamPolicy DROP_OLDEST DROP_NEWEST BLOCK

# ---------------------------------------------------------------------------
# StreamHandle
# ---------------------------------------------------------------------------

"""
    StreamHandle

The handle returned by [`start_stream`](@ref). Holds the streaming
`Channel` (in `.channel`), the background `Task`, the policy, and the
running `frames_grabbed` / `frames_dropped` counters.

Don't construct directly — use `start_stream` or `stream`.
"""
mutable struct StreamHandle
    cam::Camera
    acq::GenTL.Acquisition
    channel::Channel
    task::Task
    stop_signal::Threads.Atomic{Bool}
    grabbed::Threads.Atomic{Int}
    dropped::Threads.Atomic{Int}
    policy::StreamPolicy
    decode::Bool
    closed::Bool
end

function Base.show(io::IO, sh::StreamHandle)
    state = sh.closed ? "stopped" : (istaskdone(sh.task) ? "idle" : "running")
    print(io, "StreamHandle(", state,
        ", grabbed=", sh.grabbed[],
        ", dropped=", sh.dropped[],
        ", policy=", sh.policy, ")")
end

# ---------------------------------------------------------------------------
# start_stream
# ---------------------------------------------------------------------------

"""
    start_stream(cam; num_buffers=8, decode=true, channel_size=4,
                 policy=DROP_OLDEST, timeout_ms=1000) -> StreamHandle

Begin continuous acquisition on `cam`. Returns a [`StreamHandle`](@ref)
whose `channel` field yields decoded frames as they arrive.

Only one stream may be active per camera. The handle is also stored on
`cam.stream` so that closing the camera tears the stream down cleanly.

Arguments:
  * `num_buffers` — size of the producer's buffer pool. Larger values
    tolerate brief consumer stalls without dropping frames.
  * `decode` — when `true` (default), each frame is run through
    `PixelFormats.decode_frame` before being pushed; the channel yields
    `DecodedFrame` values. When `false`, the raw `Vector{UInt8}` payload
    is copied (so the caller can keep it after `requeue!`).
  * `channel_size` — Julia `Channel` capacity. Combine with `policy` to
    decide what happens when the consumer is slower than the producer.
  * `policy` — `DROP_OLDEST`, `DROP_NEWEST`, or `BLOCK` (see module docs).
  * `timeout_ms` — per-frame `next_frame!` timeout. Determines how often
    the streaming task checks the stop-signal.
"""
function start_stream(cam::Camera;
                       num_buffers::Integer = 8,
                       decode::Bool = true,
                       channel_size::Integer = 4,
                       policy::StreamPolicy = DROP_OLDEST,
                       timeout_ms::Integer = 1000)
    cam.closed && throw(ArgumentError("Camera is closed"))
    is_streaming(cam) && throw(ArgumentError(
        "Camera already has an active stream — call stop_stream(cam) first"))

    # The single-frame `grab` pool shares the data stream. Only one
    # EVENT_NEW_BUFFER can be registered per stream, so we must release
    # the grab pool before standing up the streaming pool.
    if cam.acquisition !== nothing
        try; close(cam.acquisition); catch; end
        cam.acquisition = nothing
    end

    # Configure for continuous acquisition. Many cameras default to
    # SingleFrame after a `grab`; switch to Continuous so AcquisitionStart
    # delivers frames until we explicitly stop.
    if haskey(cam.nodemap, "AcquisitionMode")
        try
            set_feature!(cam, :AcquisitionMode, "Continuous")
        catch
        end
    end

    # Allocate a stream-private acquisition pool (separate from the
    # single-frame `grab` pool to avoid contending on payload size).
    psize = _current_payload_size(cam)
    acq = GenTL.Acquisition(cam.datastream;
        num_buffers = num_buffers, payload_size = psize)

    channel = Channel{Any}(Int(channel_size))
    stop_sig = Threads.Atomic{Bool}(false)
    grabbed = Threads.Atomic{Int}(0)
    dropped = Threads.Atomic{Int}(0)

    # Build the streaming task before starting acquisition so a fast
    # producer doesn't fill the buffer pool before our task is reading.
    task = Threads.@spawn _stream_loop(cam, acq, channel, stop_sig,
        grabbed, dropped, policy, decode, Int(timeout_ms))

    sh = StreamHandle(cam, acq, channel, task, stop_sig,
        grabbed, dropped, policy, decode, false)
    cam.stream = sh

    try
        GenTL.start!(acq)
        execute_command!(cam, :AcquisitionStart)
    catch
        # if we couldn't start, tear everything down
        stop_signal!(sh)
        try; close(channel); catch; end
        try; GenTL.stop!(acq); catch; end
        try; close(acq); catch; end
        cam.stream = nothing
        sh.closed = true
        rethrow()
    end

    return sh
end

# ---------------------------------------------------------------------------
# Streaming loop (runs on a background task)
# ---------------------------------------------------------------------------

function _stream_loop(cam::Camera, acq::GenTL.Acquisition, channel::Channel,
                       stop_sig::Threads.Atomic{Bool},
                       grabbed::Threads.Atomic{Int},
                       dropped::Threads.Atomic{Int},
                       policy::StreamPolicy, decode::Bool,
                       timeout_ms::Int)
    try
        while !stop_sig[]
            frame = nothing
            try
                frame = GenTL.next_frame_or_timeout(acq; timeout_ms = timeout_ms)
            catch e
                @error "streaming loop: next_frame_or_timeout threw" exception = e
                break
            end
            frame === nothing && continue        # timeout — re-check stop_sig

            # Decode (allocates a fresh image) or copy the raw payload —
            # in either case we leave nothing aliasing the producer pool
            # past the requeue! below.
            payload = try
                if decode
                    _decode_with_fallback(frame, cam)
                else
                    copy(view(frame.data, 1:Int(frame.size_filled)))
                end
            catch
                # decode failure — drop frame, count, requeue, continue
                Threads.atomic_add!(dropped, 1)
                try; GenTL.requeue!(acq, frame); catch; end
                continue
            end

            # Re-queue immediately so the producer never starves while
            # the channel is blocked.
            try
                GenTL.requeue!(acq, frame)
            catch
                # acquisition stopped under us; just exit
                break
            end

            _push_with_policy!(channel, payload, policy, dropped)
            Threads.atomic_add!(grabbed, 1)
        end
    finally
        # No matter how we exit, signal the consumer side that the
        # channel is closing.
        try; close(channel); catch; end
    end
    return nothing
end

@inline function _push_with_policy!(channel::Channel, value,
                                      policy::StreamPolicy,
                                      dropped::Threads.Atomic{Int})
    if policy === BLOCK
        put!(channel, value)
        return
    end
    # Non-blocking variants
    sz = channel.sz_max
    if sz <= 0
        # unbuffered channel — fall back to BLOCK semantics
        put!(channel, value)
        return
    end
    if Base.n_avail(channel) >= sz
        if policy === DROP_OLDEST
            try
                take!(channel)         # drop oldest to make room
            catch
            end
            put!(channel, value)
            Threads.atomic_add!(dropped, 1)
        else
            # DROP_NEWEST — discard the new frame
            Threads.atomic_add!(dropped, 1)
        end
    else
        put!(channel, value)
    end
    return
end

# ---------------------------------------------------------------------------
# stop_stream / introspection
# ---------------------------------------------------------------------------

"""
    stop_stream(cam) -> nothing

Stop the active stream on `cam`: signal the producer task to exit, send
`AcquisitionStop` to the camera, drain and close the channel, and tear
down the acquisition pool. No-op if no stream is active.
"""
function stop_stream(cam::Camera)
    sh = cam.stream
    sh === nothing && return nothing
    _shutdown_stream!(sh)
    # Leave the closed StreamHandle on `cam.stream` so post-stop calls to
    # `frames_grabbed(cam)` / `frames_dropped(cam)` still report the
    # final stats. `is_streaming(cam)` returns false on a closed handle,
    # and the next `start_stream` overwrites it.
    return nothing
end

stop_signal!(sh::StreamHandle) = (sh.stop_signal[] = true; nothing)

function _shutdown_stream!(sh::StreamHandle)
    sh.closed && return sh
    stop_signal!(sh)
    # Stop the camera so the producer pool drains; the task will then
    # see timeouts and exit on its next iteration.
    try
        execute_command!(sh.cam, :AcquisitionStop)
    catch
    end
    # Wait for the streaming task to finish (timeout-bounded — if the
    # task has gone fully wedged we don't want to hang the user forever).
    if !istaskdone(sh.task)
        wait_until = time() + 5.0
        while !istaskdone(sh.task) && time() < wait_until
            sleep(0.05)
        end
    end
    try; close(sh.channel); catch; end
    try; GenTL.stop!(sh.acq); catch e
        e isa GenTL.GenTLError && e.code == GenTL.GC_ERR_RESOURCE_IN_USE || nothing
    end
    try; close(sh.acq); catch; end
    sh.closed = true
    return sh
end

"""
    is_streaming(cam) -> Bool
"""
is_streaming(cam::Camera) =
    cam.stream !== nothing && !cam.stream.closed && !istaskdone(cam.stream.task)

"""
    frames_grabbed(cam) -> Int

Number of frames the streaming task has successfully delivered to its
channel. Counts only frames that were actually pushed; frames dropped by
the policy are tracked separately by [`frames_dropped`](@ref).
"""
frames_grabbed(cam::Camera) =
    cam.stream === nothing ? 0 : cam.stream.grabbed[]

"""
    frames_dropped(cam) -> Int

Number of frames the streaming task has dropped (because the channel was
full and the policy was `DROP_OLDEST` or `DROP_NEWEST`, or because decode
failed for that frame).
"""
frames_dropped(cam::Camera) =
    cam.stream === nothing ? 0 : cam.stream.dropped[]

# ---------------------------------------------------------------------------
# stream — Channel-returning convenience + do-block variant
# ---------------------------------------------------------------------------

"""
    stream(cam; kwargs...) -> Channel

Convenience wrapper: returns the streaming channel directly so you can
write `for img in stream(cam)`. Forwards all keyword arguments to
[`start_stream`](@ref). The caller is responsible for `stop_stream(cam)`.
"""
function stream(cam::Camera; kwargs...)
    return start_stream(cam; kwargs...).channel
end

"""
    stream(f, cam; kwargs...)

Do-block variant — calls `f(channel)` while streaming, then guarantees
`stop_stream(cam)` is called on exit (success or exception).

```julia
imgs = stream(cam) do ch
    [take!(ch) for _ in 1:30]
end
```
"""
function stream(f::Function, cam::Camera; kwargs...)
    sh = start_stream(cam; kwargs...)
    try
        return f(sh.channel)
    finally
        stop_stream(cam)
    end
end
