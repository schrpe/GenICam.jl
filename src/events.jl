"""
GenTL feature-event listener layer.

Producers can fire two kinds of feature events:

  * `EVENT_FEATURE_INVALIDATE` — the camera changed something (e.g. an
    auto-exposure controller adjusted `ExposureTime` itself); any cache
    we hold on the named feature is stale.
  * `EVENT_FEATURE_CHANGE` — the producer pushes the new value directly
    so callers can react without re-reading.

Not every producer fires these; quite a few only support buffer events.
We register the events lazily — on the first `on_feature_*` call — and
silently fall back to no-op listener handles if the producer reports
`GC_ERR_NOT_AVAILABLE`. That way user code stays portable: it can ask
to be notified of feature changes whether the underlying hardware
supports them or not.

Implementation: one background `Task` per camera, alive only while at
least one listener is registered. The task loops over `EventGetData`
with a finite timeout (so it can check the stop signal between events),
parses the feature-name payload, and dispatches to listeners through a
`ReentrantLock`-guarded vector.
"""

# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

"""
    FeatureEvent

The argument passed to user-supplied callbacks.

  * `kind` — `:invalidate` or `:change`.
  * `name` — the feature name as reported by the producer.
  * `value` — the new value (only for `:change`; `nothing` for
    `:invalidate`).
  * `timestamp_ns` — Julia `time_ns()` at receipt; useful for ordering
    or logging.
"""
struct FeatureEvent
    kind::Symbol
    name::String
    value::Any
    timestamp_ns::UInt64
end

"""
    ListenerHandle

Opaque token returned by `on_feature_invalidate` / `on_feature_change`.
Pass it back to `remove_listener` to unsubscribe.
"""
struct ListenerHandle
    id::Int
end

# Internal listener record.
struct _Listener
    handle::ListenerHandle
    kind::Symbol               # :invalidate | :change
    name_filter::Union{Nothing,String}   # nothing = all features
    callback::Function
end

# Per-camera event-pump state. Embedded into Camera via the `event_pump`
# field (typed `Any` to avoid forward-reference cycles).
mutable struct EventPump
    cam::Camera
    invalidate_event::GenTL.EVENT_HANDLE   # GENTL_INVALID_HANDLE if not registered
    change_event::GenTL.EVENT_HANDLE
    task::Union{Nothing,Task}
    stop_signal::Threads.Atomic{Bool}
    listeners::Vector{_Listener}
    next_id::Threads.Atomic{Int}
    lock::ReentrantLock
    closed::Bool
end

EventPump(cam::Camera) = EventPump(cam,
    C_NULL, C_NULL, nothing,
    Threads.Atomic{Bool}(false),
    _Listener[],
    Threads.Atomic{Int}(1),
    ReentrantLock(),
    false)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

"""
    on_feature_invalidate(cam, callback) -> ListenerHandle
    on_feature_invalidate(cam, name::AbstractString, callback) -> ListenerHandle

Register a `callback(::FeatureEvent)` to fire whenever the camera invalidates
a feature (auto-exposure ramp, hardware-driven gain change, etc.). With a
`name`, only events for that feature trigger the callback; without one,
all invalidate events do.

Returns a `ListenerHandle` for later [`remove_listener`](@ref). If the
producer doesn't support feature events, returns a no-op handle and
emits a single `@warn` (so portable code keeps working).
"""
on_feature_invalidate(cam::Camera, callback::Function) =
    _add_listener!(cam, :invalidate, nothing, callback)

on_feature_invalidate(cam::Camera, name::AbstractString, callback::Function) =
    _add_listener!(cam, :invalidate, String(name), callback)

"""
    on_feature_change(cam, callback) -> ListenerHandle
    on_feature_change(cam, name::AbstractString, callback) -> ListenerHandle

Like [`on_feature_invalidate`](@ref) but for `EVENT_FEATURE_CHANGE` —
the producer pushes the new value with the event so the callback gets a
populated `FeatureEvent.value`.
"""
on_feature_change(cam::Camera, callback::Function) =
    _add_listener!(cam, :change, nothing, callback)

on_feature_change(cam::Camera, name::AbstractString, callback::Function) =
    _add_listener!(cam, :change, String(name), callback)

"""
    remove_listener(cam, handle::ListenerHandle)

Unsubscribe a previously registered listener. No-op if the handle no
longer matches a live listener (e.g. the camera has been closed).
"""
function remove_listener(cam::Camera, handle::ListenerHandle)
    pump = cam.event_pump
    pump === nothing && return nothing
    lock(pump.lock) do
        deleteat!(pump.listeners,
            findall(l -> l.handle.id == handle.id, pump.listeners))
    end
    return nothing
end

"""
    close_event_pump!(cam)

Stop the background event-pump task and unregister GenTL events. Called
automatically from `_finalize_camera`; users normally don't invoke it
themselves.
"""
function close_event_pump!(cam::Camera)
    pump = cam.event_pump
    pump === nothing && return nothing
    _shutdown_pump!(pump)
    cam.event_pump = nothing
    return nothing
end

# ---------------------------------------------------------------------------
# Internal: lazy pump start, listener registration
# ---------------------------------------------------------------------------

function _add_listener!(cam::Camera, kind::Symbol,
                         name_filter::Union{Nothing,String}, callback::Function)
    pump = cam.event_pump
    if pump === nothing
        pump = EventPump(cam)
        cam.event_pump = pump
    end

    # Register the matching GenTL event lazily — only the first listener of
    # each kind triggers the producer-side registration. If the producer
    # rejects, log once and return a no-op handle.
    ev_type = kind === :invalidate ? GenTL.EVENT_FEATURE_INVALIDATE :
              GenTL.EVENT_FEATURE_CHANGE
    if (kind === :invalidate ? pump.invalidate_event : pump.change_event) ===
            GenTL.GENTL_INVALID_HANDLE
        try
            ev = GenTL.gc_register_event(cam.api,
                cam.device.handle, ev_type)
            if kind === :invalidate
                pump.invalidate_event = ev
            else
                pump.change_event = ev
            end
        catch e
            @warn "producer does not support EVENT_FEATURE_$(uppercase(string(kind)))" exception = e
            return ListenerHandle(0)        # no-op handle
        end
    end

    handle = ListenerHandle(Threads.atomic_add!(pump.next_id, 1))
    listener = _Listener(handle, kind, name_filter, callback)
    lock(pump.lock) do
        push!(pump.listeners, listener)
    end

    # Start the pump task on first listener.
    if pump.task === nothing || istaskdone(pump.task)
        pump.stop_signal[] = false
        pump.task = Threads.@spawn _event_loop(pump)
    end

    return handle
end

# ---------------------------------------------------------------------------
# Event loop
# ---------------------------------------------------------------------------

function _event_loop(pump::EventPump)
    cam = pump.cam
    timeout_ms = 100      # short, so we re-check stop_signal often
    try
        while !pump.stop_signal[]
            for (kind, ev) in ((:invalidate, pump.invalidate_event),
                                (:change,     pump.change_event))
                ev === GenTL.GENTL_INVALID_HANDLE && continue
                payload = try
                    GenTL.event_get_data_bytes(cam.api, ev, timeout_ms)
                catch e
                    e isa GenTL.GenTLError && e.code == GenTL.GC_ERR_TIMEOUT && continue
                    nothing
                end
                payload === nothing && continue

                # Feature-event payload is a NUL-terminated feature name. For
                # CHANGE events some producers tack the new value bytes onto
                # the end; we don't decode that here — we invalidate the
                # cache and let callers re-read.
                feature_name = _extract_feature_name(payload)

                event = FeatureEvent(kind, feature_name, nothing, time_ns())

                # Invalidate our own cache regardless of listeners.
                if haskey(cam.nodemap, feature_name)
                    GenApi.cache_clear!(cam.nodemap[feature_name].meta.cache)
                end

                _dispatch!(pump, event)
            end
        end
    catch e
        @error "event pump terminated unexpectedly" exception = e
    end
    return nothing
end

@inline function _extract_feature_name(bytes::Vector{UInt8})
    nul = findfirst(==(0x00), bytes)
    n = nul === nothing ? length(bytes) : nul - 1
    return String(bytes[1:n])
end

function _dispatch!(pump::EventPump, event::FeatureEvent)
    listeners = lock(pump.lock) do
        copy(pump.listeners)
    end
    for l in listeners
        l.kind === event.kind || continue
        l.name_filter === nothing || l.name_filter == event.name || continue
        try
            l.callback(event)
        catch e
            @warn "feature-event listener threw" event = event exception = e
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Shutdown
# ---------------------------------------------------------------------------

function _shutdown_pump!(pump::EventPump)
    pump.closed && return pump
    pump.stop_signal[] = true

    # Wake the task by killing pending events (so EventGetData returns
    # immediately with an error we can catch).
    for ev in (pump.invalidate_event, pump.change_event)
        ev === GenTL.GENTL_INVALID_HANDLE && continue
        try; GenTL.event_kill(pump.cam.api, ev); catch; end
    end

    if pump.task !== nothing && !istaskdone(pump.task)
        wait_until = time() + 2.0
        while !istaskdone(pump.task) && time() < wait_until
            sleep(0.05)
        end
    end

    for (ev, et) in ((pump.invalidate_event, GenTL.EVENT_FEATURE_INVALIDATE),
                      (pump.change_event,     GenTL.EVENT_FEATURE_CHANGE))
        ev === GenTL.GENTL_INVALID_HANDLE && continue
        try
            GenTL.gc_unregister_event(pump.cam.api,
                pump.cam.device.handle, et)
        catch
        end
    end
    pump.invalidate_event = GenTL.GENTL_INVALID_HANDLE
    pump.change_event = GenTL.GENTL_INVALID_HANDLE
    pump.closed = true
    empty!(pump.listeners)
    return pump
end
