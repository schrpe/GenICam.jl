"""
Buffer & event handling for GenTL acquisition.

This file wraps the producer's buffer/queue model: Julia owns the pixel
backing storage as `Vector{UInt8}`; we hand each buffer's pointer to the
producer via `DSAnnounceBuffer`, queue it with `DSQueueBuffer`, then wait
for `EVENT_NEW_BUFFER` to know when the producer has filled it.

Critical: while a buffer is announced, its backing `Vector{UInt8}` must not
be garbage-collected. The `Acquisition` struct keeps strong references in
its `pool` field. Don't drop the `Acquisition` (or its buffer vectors) while
the producer might still write into them — call `stop!` and `revoke_all!`
first.
"""

# ---------------------------------------------------------------------------
# Buffer wrapper
# ---------------------------------------------------------------------------

"""
    AcquisitionBuffer

One announced buffer. Owns:
  - `data` : the Julia-allocated `Vector{UInt8}` whose pointer we gave the
    producer
  - `handle` : the opaque `BUFFER_HANDLE` returned by `DSAnnounceBuffer`
"""
mutable struct AcquisitionBuffer
    data::Vector{UInt8}
    handle::BUFFER_HANDLE
end

# ---------------------------------------------------------------------------
# Acquisition session
# ---------------------------------------------------------------------------

"""
    Acquisition(ds; num_buffers=4, payload_size=nothing)

Set up an acquisition on `ds` (a `DataStream`):
  1. Determines the buffer size — uses `payload_size` if given, else queries
     `STREAM_INFO_PAYLOAD_SIZE`.
  2. Allocates `num_buffers` Julia vectors of that size.
  3. Announces and queues each one.
  4. Registers an `EVENT_NEW_BUFFER` event so subsequent calls to
     `next_frame!` can block on it.

The `Acquisition` is *not* yet running — call `start!(acq)` to begin.
"""
mutable struct Acquisition
    ds::DataStream
    pool::Vector{AcquisitionBuffer}
    event::EVENT_HANDLE
    payload_size::Csize_t
    started::Bool
    closed::Bool
end

function Acquisition(ds::DataStream;
                     num_buffers::Integer = 4,
                     payload_size::Union{Integer,Nothing} = nothing)
    api = api_of(ds)
    psize = payload_size === nothing ?
        ds_get_info(api, ds.handle, STREAM_INFO_PAYLOAD_SIZE, Csize_t) :
        Csize_t(payload_size)
    psize == 0 && throw(ArgumentError(
        "payload size is 0; pass an explicit `payload_size` to Acquisition"))

    pool = AcquisitionBuffer[]
    sizehint!(pool, num_buffers)
    try
        for _ in 1:num_buffers
            data = Vector{UInt8}(undef, Int(psize))
            ptr = pointer(data)
            h = ds_announce_buffer(api, ds.handle, ptr, Int(psize))
            push!(pool, AcquisitionBuffer(data, h))
            ds_queue_buffer(api, ds.handle, h)
        end
        ev = gc_register_event(api, ds.handle, EVENT_NEW_BUFFER)
        acq = Acquisition(ds, pool, ev, psize, false, false)
        finalizer(_finalize_acquisition, acq)
        return acq
    catch
        # roll back any partially announced buffers
        for b in pool
            try
                ds_revoke_buffer(api, ds.handle, b.handle)
            catch
            end
        end
        rethrow()
    end
end

function _finalize_acquisition(acq::Acquisition)
    acq.closed && return
    api = api_of(acq.ds)
    if acq.started
        try
            ds_stop_acquisition(api, acq.ds.handle; flags = ACQ_STOP_FLAGS_KILL)
        catch
        end
        acq.started = false
    end
    try
        gc_unregister_event(api, acq.ds.handle, EVENT_NEW_BUFFER)
    catch
    end
    for b in acq.pool
        try
            ds_revoke_buffer(api, acq.ds.handle, b.handle)
        catch
        end
    end
    acq.closed = true
    return
end

function Base.close(acq::Acquisition)
    acq.closed && return nothing
    api = api_of(acq.ds)
    if acq.started
        try
            ds_stop_acquisition(api, acq.ds.handle)
        catch
        end
        acq.started = false
    end
    try
        ds_flush_queue(api, acq.ds.handle, ACQ_QUEUE_ALL_DISCARD)
    catch
    end
    try
        event_flush(api, acq.event)
    catch
    end
    try
        gc_unregister_event(api, acq.ds.handle, EVENT_NEW_BUFFER)
    catch
    end
    for b in acq.pool
        try
            ds_revoke_buffer(api, acq.ds.handle, b.handle)
        catch
        end
    end
    acq.closed = true
    return nothing
end

Base.show(io::IO, acq::Acquisition) =
    print(io, "Acquisition(", length(acq.pool), " buffers @ ",
        Int(acq.payload_size), " bytes, ",
        acq.closed ? "closed" :
            acq.started ? "running" : "ready", ")")

# ---------------------------------------------------------------------------
# Acquisition control
# ---------------------------------------------------------------------------

"""
    start!(acq; num_to_acquire=GENTL_INFINITE)

Start the data stream. Subsequent `next_frame!` calls will block until
the producer signals a new buffer.
"""
function start!(acq::Acquisition;
                 num_to_acquire::Integer = GENTL_INFINITE)
    acq.closed && throw(ArgumentError("Acquisition is closed"))
    acq.started && return acq
    api = api_of(acq.ds)
    ds_flush_queue(api, acq.ds.handle, ACQ_QUEUE_ALL_TO_INPUT)
    ds_start_acquisition(api, acq.ds.handle;
        num_to_acquire = num_to_acquire)
    acq.started = true
    return acq
end

"""
    stop!(acq; kill=false)

Stop the data stream. If `kill=true` the acquisition engine is told to abort
in-flight buffers (`ACQ_STOP_FLAGS_KILL`); otherwise it finishes the current
buffer cleanly (`ACQ_STOP_FLAGS_DEFAULT`).
"""
function stop!(acq::Acquisition; kill::Bool = false)
    acq.started || return acq
    api = api_of(acq.ds)
    flags = kill ? ACQ_STOP_FLAGS_KILL : ACQ_STOP_FLAGS_DEFAULT
    ds_stop_acquisition(api, acq.ds.handle; flags = flags)
    acq.started = false
    return acq
end

# ---------------------------------------------------------------------------
# Frame retrieval
# ---------------------------------------------------------------------------

"""
    Frame

Lightweight view onto a single completed acquisition buffer. The `data`
field aliases the producer's pixel memory (which is the same `Vector{UInt8}`
we announced) — copy it before the buffer is re-queued if you need to keep
the bytes around.

`chunks` holds the per-frame metadata dict once `decode_chunks!` has been
run; otherwise it's `nothing`. Mutable so the chunks layer can attach
without rebuilding the whole struct.
"""
mutable struct Frame
    handle::BUFFER_HANDLE
    data::Vector{UInt8}
    size_filled::Csize_t
    width::Csize_t
    height::Csize_t
    pixel_format::UInt64
    pixel_format_namespace::UInt64
    incomplete::Bool
    chunks::Union{Nothing,Dict{Symbol,Any}}
end

# Convenience positional constructor — `chunks` defaults to nothing.
Frame(handle, data, size_filled, width, height,
      pixel_format, pixel_format_namespace, incomplete) =
    Frame(handle, data, size_filled, width, height,
          pixel_format, pixel_format_namespace, incomplete, nothing)

function Base.show(io::IO, f::Frame)
    print(io, "Frame(", f.width, "x", f.height,
        ", filled=", Int(f.size_filled),
        ", pixfmt=0x", string(f.pixel_format; base = 16),
        f.incomplete ? ", INCOMPLETE" : "",
        f.chunks === nothing ? "" : ", chunks=$(length(f.chunks))",
        ")")
end

"""
    next_frame!(acq; timeout_ms=1000) -> Frame

Block up to `timeout_ms` for the producer to signal a new buffer, then return
a `Frame` whose `data` aliases the buffer's bytes. The buffer is *not* yet
re-queued — call `requeue!(acq, frame)` after consuming the data.
"""
function next_frame!(acq::Acquisition; timeout_ms::Integer = 1000)
    acq.closed && throw(ArgumentError("Acquisition is closed"))
    api = api_of(acq.ds)
    ev = event_get_data(api, acq.event, EVENT_NEW_BUFFER_DATA, timeout_ms)
    h = ev.BufferHandle

    buf = _find_buffer(acq, h)
    buf === nothing && throw(GenTLError(GC_ERR_INVALID_BUFFER,
        "EVENT_NEW_BUFFER returned an unknown buffer handle"))

    filled = ds_get_buffer_info(api, acq.ds.handle, h,
        BUFFER_INFO_SIZE_FILLED, Csize_t)
    width = _try_buffer_info(api, acq.ds.handle, h,
        BUFFER_INFO_WIDTH, Csize_t, Csize_t(0))
    height = _try_buffer_info(api, acq.ds.handle, h,
        BUFFER_INFO_HEIGHT, Csize_t, Csize_t(0))
    pf = _try_buffer_info(api, acq.ds.handle, h,
        BUFFER_INFO_PIXELFORMAT, UInt64, UInt64(0))
    pfns = _try_buffer_info(api, acq.ds.handle, h,
        BUFFER_INFO_PIXELFORMAT_NAMESPACE, UInt64, UInt64(0))
    incomplete = _try_buffer_info(api, acq.ds.handle, h,
        BUFFER_INFO_IS_INCOMPLETE, UInt8, UInt8(0)) != 0

    return Frame(h, buf.data, filled, width, height, pf, pfns, incomplete)
end

"""
    requeue!(acq, frame)

Return a `Frame`'s underlying buffer to the input pool so it can be filled
again. Must be called for every frame obtained via `next_frame!` while the
acquisition is still running.
"""
function requeue!(acq::Acquisition, f::Frame)
    api = api_of(acq.ds)
    ds_queue_buffer(api, acq.ds.handle, f.handle)
    return acq
end

"""
    next_frame_or_timeout(acq; timeout_ms=1000) -> Frame or nothing

Like [`next_frame!`](@ref), but returns `nothing` on `GC_ERR_TIMEOUT`
instead of throwing. Useful for streaming loops that need to poll a
stop-signal between frames without paying the exception-throwing cost.
"""
function next_frame_or_timeout(acq::Acquisition; timeout_ms::Integer = 1000)
    try
        return next_frame!(acq; timeout_ms = timeout_ms)
    catch e
        e isa GenTLError && e.code == GC_ERR_TIMEOUT && return nothing
        rethrow()
    end
end

function _find_buffer(acq::Acquisition, h::BUFFER_HANDLE)
    for b in acq.pool
        b.handle == h && return b
    end
    return nothing
end

function _try_buffer_info(api::ProducerAPI, ds::DS_HANDLE, h::BUFFER_HANDLE,
                          cmd::BUFFER_INFO_CMD, ::Type{T}, default::T) where {T}
    try
        return ds_get_buffer_info(api, ds, h, cmd, T)
    catch
        return default
    end
end
