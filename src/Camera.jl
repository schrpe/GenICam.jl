"""
High-level camera API.

A `Camera` bundles every layer needed to talk to one device:

    Producer -> Interface -> Device -> DataStream
                                    \\-> Port + Nodemap (parsed XML)
                                    \\-> Acquisition (lazy, created on first
                                                       grab)

Two ways to read/write features:

  1. Explicit calls (the core)::

         set_feature!(cam, :Width, 640)
         get_feature(cam, :PixelFormat)
         execute_command!(cam, :AcquisitionStart)

  2. Property syntax (a thin convenience layer over the calls above)::

         cam.Width = 640
         cam.PixelFormat = "Mono8"
         w = cam.Width

`Base.propertynames(cam)` lists every named feature in the parsed nodemap
so the Julia REPL's tab completion just works.
"""

# ---------------------------------------------------------------------------
# Camera type
# ---------------------------------------------------------------------------

"""
    Camera

The high-level handle for one open camera. Bundles every layer needed to
talk to it:

  * the parent `Producer` / `Interface` / `Device` / `DataStream`
  * the camera's port handle and a parsed `Nodemap`
  * an optional cached single-frame `Acquisition` (for `grab`)
  * an optional `StreamHandle` (for `stream` / `start_stream`)
  * the chunk-binding cache and last-frame chunk dict
  * the lazy event pump for feature-event listeners

Construct via [`open_camera`](@ref); release via `close(cam)`.
"""
mutable struct Camera
    producer::GenTL.Producer
    interface::GenTL.Interface
    device::GenTL.Device
    datastream::GenTL.DataStream
    port::GenTL.PORT_HANDLE
    api::GenTL.ProducerAPI
    nodemap::GenApi.Nodemap
    acquisition::Union{Nothing,GenTL.Acquisition}
    stream::Any                # StreamHandle | Nothing — typed Any to break a forward-ref cycle with streaming.jl
    chunk_bindings::Any        # Vector{ChunkBinding} — typed Any so chunks.jl can define the struct after Camera
    last_chunks::Union{Nothing,Dict{Symbol,Any}}
    event_pump::Any            # EventPump | Nothing — typed Any to break a forward-ref cycle with events.jl
    closed::Bool
end

function Base.show(io::IO, cam::Camera)
    if cam.closed
        print(io, "Camera(closed)")
    else
        print(io, "Camera(", cam.device.id, ", ",
            length(cam.nodemap.nodes), " nodes)")
    end
end

# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

"""
    list_cameras(producer; refresh=true) -> Vector{NamedTuple}

Walk every interface of `producer` and return one entry per visible device,
each with the parent interface info attached so callers can pass it back to
[`open_camera`](@ref).
"""
function list_cameras(producer::GenTL.Producer; refresh::Bool = true,
                       timeout_ms::Integer = 1000)
    out = NamedTuple{(:interface, :device),
        Tuple{GenTL.InterfaceInfo,GenTL.DeviceInfo}}[]
    for ifinfo in GenTL.list_interfaces(producer; refresh = refresh,
                                          timeout_ms = timeout_ms)
        iface = GenTL.open_interface(producer, ifinfo)
        try
            for d in GenTL.list_devices(iface; refresh = refresh,
                                         timeout_ms = timeout_ms)
                push!(out, (interface = ifinfo, device = d))
            end
        finally
            close(iface)
        end
    end
    return out
end

"""
    open_camera(producer, interface_info, device_info;
                access=DEVICE_ACCESS_CONTROL) -> Camera

Open the full chain (Interface → Device → DataStream) for one device, load
its GenApi XML node-map, and return a `Camera` ready for feature access and
acquisition.
"""
function open_camera(producer::GenTL.Producer,
                      ifinfo::GenTL.InterfaceInfo,
                      devinfo::GenTL.DeviceInfo;
                      access::GenTL.DEVICE_ACCESS_FLAGS =
                          GenTL.DEVICE_ACCESS_CONTROL)
    iface = GenTL.open_interface(producer, ifinfo)
    local device, ds, nodemap, port, api
    try
        device = GenTL.open_device(iface, devinfo; access = access)
        try
            ds = GenTL.open_datastream(device)
            try
                api = GenTL.api_of(device)
                port = device.port
                xml = GenApi.load_xml(port, api)
                nodemap = GenApi.parse_nodemap(xml)
            catch
                close(ds)
                rethrow()
            end
        catch
            close(device)
            rethrow()
        end
    catch
        close(iface)
        rethrow()
    end

    cam = Camera(producer, iface, device, ds, port, api,
        nodemap, nothing, nothing, [], nothing, nothing, false)
    finalizer(_finalize_camera, cam)
    return cam
end

"""
    open_camera(producer, idx::Integer = 1) -> Camera

Convenience: open the `idx`-th camera reported by `list_cameras(producer)`.
"""
function open_camera(producer::GenTL.Producer, idx::Integer = 1;
                      kwargs...)
    cams = list_cameras(producer)
    isempty(cams) && error("no cameras visible to producer")
    1 <= idx <= length(cams) || throw(BoundsError(cams, idx))
    return open_camera(producer, cams[idx].interface, cams[idx].device;
        kwargs...)
end

function _finalize_camera(cam::Camera)
    cam.closed && return
    if cam.event_pump !== nothing
        try
            close_event_pump!(cam)
        catch
        end
    end
    if cam.stream !== nothing
        try
            stop_stream(cam)
        catch
        end
    end
    if cam.acquisition !== nothing
        try
            close(cam.acquisition)
        catch
        end
        cam.acquisition = nothing
    end
    try
        close(cam.datastream)
    catch
    end
    try
        close(cam.device)
    catch
    end
    try
        close(cam.interface)
    catch
    end
    cam.closed = true
    return
end

function Base.close(cam::Camera)
    cam.closed && return nothing
    if cam.event_pump !== nothing
        try; close_event_pump!(cam); catch; end
    end
    if cam.stream !== nothing
        stop_stream(cam)
    end
    if cam.acquisition !== nothing
        close(cam.acquisition)
        cam.acquisition = nothing
    end
    close(cam.datastream)
    close(cam.device)
    close(cam.interface)
    cam.closed = true
    return nothing
end

# ---------------------------------------------------------------------------
# Feature access — explicit API
# ---------------------------------------------------------------------------

const FeatureName = Union{Symbol,AbstractString}

"""
    get_feature(cam, name) -> value
"""
get_feature(cam::Camera, name::FeatureName) =
    GenApi.get_value(cam.nodemap, String(name), cam.port, cam.api)

"""
    set_feature!(cam, name, value)
"""
set_feature!(cam::Camera, name::FeatureName, value) =
    GenApi.set_value!(cam.nodemap, String(name), value, cam.port, cam.api)

"""
    execute_command!(cam, name)
"""
execute_command!(cam::Camera, name::FeatureName) =
    GenApi.execute!(cam.nodemap, String(name), cam.port, cam.api)

# ---------------------------------------------------------------------------
# Feature access — getproperty / setproperty! convenience
# ---------------------------------------------------------------------------

const _CAMERA_FIELDS = fieldnames(Camera)

function Base.getproperty(cam::Camera, name::Symbol)
    name in _CAMERA_FIELDS && return getfield(cam, name)
    return get_feature(cam, name)
end

function Base.setproperty!(cam::Camera, name::Symbol, value)
    if name in _CAMERA_FIELDS
        return setfield!(cam, name, value)
    end
    set_feature!(cam, name, value)
    return value
end

Base.propertynames(cam::Camera, _private::Bool = false) =
    Symbol[Symbol(n) for n in cam.nodemap.feature_names]

# ---------------------------------------------------------------------------
# Acquisition / grab
# ---------------------------------------------------------------------------

function _ensure_acquisition!(cam::Camera; num_buffers::Integer = 4)
    psize = _current_payload_size(cam)
    # If we already have an acquisition pool sized for this payload, reuse it.
    # Otherwise (PixelFormat or AOI changed → new payload size) tear it down
    # and rebuild — too-small buffers cause the producer to drop INCOMPLETE
    # frames and surface as opaque acquisition failures.
    if cam.acquisition !== nothing
        if cam.acquisition.payload_size == psize && !cam.acquisition.closed
            return cam.acquisition
        end
        close(cam.acquisition)
        cam.acquisition = nothing
    end
    cam.acquisition = GenTL.Acquisition(cam.datastream;
        num_buffers = num_buffers, payload_size = psize)
    return cam.acquisition
end

function _current_payload_size(cam::Camera)
    psize = try
        GenTL.ds_get_info(cam.api, cam.datastream.handle,
            GenTL.STREAM_INFO_PAYLOAD_SIZE, Csize_t)
    catch
        Csize_t(0)
    end
    if psize == 0 && haskey(cam.nodemap, "PayloadSize")
        psize = Csize_t(get_feature(cam, :PayloadSize))
    end
    return psize
end

"""
    grab(cam; timeout_ms=2000, num_buffers=4) -> DecodedFrame

Grab one frame in single-frame acquisition mode and return it as a
[`DecodedFrame`](@ref) whose `image` field is a typed Julia matrix matching
the camera's current `PixelFormat`:

  * `Mono8` / `Mono16` / `Mono10` / `Mono12` / `Mono14` / packed mono variants
    → `Matrix{Gray{N0f8}}` or `Matrix{Gray{N0f16}}`
  * `RGB8` / `BGR8` → `Matrix{RGB{N0f8}}` / `Matrix{BGR{N0f8}}`
  * `RGB10`/`12`/`14`/`16`, `RGB10p32`, `BGR10p32` → `Matrix{RGB{N0f16}}`
  * `RGBa8` / `BGRa8` → `Matrix{RGBA{N0f8}}` / `Matrix{BGRA{N0f8}}`
  * `BayerXX*` → `Matrix{Gray{N0fX}}` plus a `cfa` tag (no demosaicing — pass
    the result through `Images.jl` or your own demosaic to get an RGB image)
  * `YUV422_*`, `YUV411_*`, `YUV8_UYV` → `Matrix{RGB{N0f8}}` (BT.601 conversion)

The matrix has shape `(height, width)` with `img[row, col]` indexing
naturally. The acquisition buffer pool is created lazily on the first call
and reused on subsequent calls; `close(cam)` tears it down.

Use [`grab_raw`](@ref) if you want the unparsed `Vector{UInt8}` payload.
"""
function grab(cam::Camera; timeout_ms::Integer = 2000,
               num_buffers::Integer = 4)
    return _grab_dispatch(cam, timeout_ms, num_buffers, true)
end

"""
    grab_raw(cam; timeout_ms=2000, num_buffers=4) -> Vector{UInt8}

Like [`grab`](@ref) but skip pixel-format decoding and return the producer's
raw payload bytes. The buffer is owned and may be retained — it has been
copied out of the GenTL pool before this returns.
"""
function grab_raw(cam::Camera; timeout_ms::Integer = 2000,
                   num_buffers::Integer = 4)
    return _grab_dispatch(cam, timeout_ms, num_buffers, false)
end

function _grab_dispatch(cam::Camera, timeout_ms::Integer,
                        num_buffers::Integer, decode::Bool)
    cam.closed && throw(ArgumentError("Camera is closed"))

    # Configure single-frame acquisition. AcquisitionMode is mandatory per
    # SFNC and every camera is required to support "SingleFrame".
    if haskey(cam.nodemap, "AcquisitionMode")
        try
            set_feature!(cam, :AcquisitionMode, "SingleFrame")
        catch
            # some cameras name the value differently; fall through and let
            # the user pre-configure the mode
        end
    end

    acq = _ensure_acquisition!(cam; num_buffers = num_buffers)

    GenTL.start!(acq; num_to_acquire = 1)
    try
        execute_command!(cam, :AcquisitionStart)
        try
            frame = GenTL.next_frame!(acq; timeout_ms = timeout_ms)
            try
                frame.incomplete && @warn "frame marked INCOMPLETE by producer"
                # Pull chunk metadata if the camera has chunks enabled.
                if !isempty(cam.chunk_bindings)
                    decode_chunks!(frame, cam)
                    cam.last_chunks = frame.chunks
                end
                return decode ? _decode_with_fallback(frame, cam) :
                                copy(view(frame.data, 1:Int(frame.size_filled)))
            finally
                # Re-queue may fail once the producer has auto-stopped its
                # engine after the requested frame; that's harmless.
                try
                    GenTL.requeue!(acq, frame)
                catch
                end
            end
        finally
            try
                execute_command!(cam, :AcquisitionStop)
            catch
                # AcquisitionStop may legitimately fail in single-frame mode
                # if the camera has already auto-stopped
            end
        end
    finally
        # Producer auto-stops the data-stream engine after `num_to_acquire`
        # frames; calling DSStopAcquisition then yields GC_ERR_RESOURCE_IN_USE
        # ("not currently running"). Treat that as success.
        try
            GenTL.stop!(acq)
        catch e
            e isa GenTL.GenTLError &&
                e.code == GenTL.GC_ERR_RESOURCE_IN_USE || rethrow()
        end
        # Sync our state with the producer so subsequent calls don't try to
        # stop an already-stopped engine.
        acq.started = false
    end
end

# Decode by code first; fall back to the GenApi `PixelFormat` enumeration
# string if the producer reports an unknown (namespace, code) pair — which
# happens with older producers that don't populate the namespace field.
function _decode_with_fallback(frame::GenTL.Frame, cam::Camera)
    spec = PixelFormats.spec_for_code(frame.pixel_format_namespace,
                                        frame.pixel_format)
    if spec === nothing && haskey(cam.nodemap, "PixelFormat")
        try
            name = Symbol(get_feature(cam, :PixelFormat))
            return PixelFormats.decode_frame(_with_geometry(frame, cam);
                pixel_format_hint = name)
        catch
            # fall through to throw the UnsupportedPixelFormat from decode_frame
        end
    end
    return PixelFormats.decode_frame(_with_geometry(frame, cam))
end

# If frame.width/height are 0, build a synthetic Frame with the GenApi
# Width/Height filled in. Doesn't touch the underlying buffer.
function _with_geometry(frame::GenTL.Frame, cam::Camera)
    if frame.width != 0 && frame.height != 0
        return frame
    end
    w = Csize_t(haskey(cam.nodemap, "Width") ?
        Int(get_feature(cam, :Width)) : 0)
    h = Csize_t(haskey(cam.nodemap, "Height") ?
        Int(get_feature(cam, :Height)) : 0)
    return GenTL.Frame(frame.handle, frame.data, frame.size_filled,
        w, h, frame.pixel_format, frame.pixel_format_namespace,
        frame.incomplete)
end
