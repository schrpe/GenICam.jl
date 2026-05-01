"""
Multi-producer enumeration and hot-plug detection.

`list_all_cameras()` walks every `.cti` in `GENICAM_GENTL64_PATH`,
opens it transiently, enumerates its devices, closes it again — handy
when you don't yet know which producer your camera lives behind.

`watch_devices(producer)` (and the multi-producer variant
`watch_all_producers()`) spawn a background `Task` that polls
`TLUpdateInterfaceList` + `IFUpdateDeviceList` and emits a
`DeviceEvent` on a `Channel` whenever a device appears or disappears.
Useful for live device-list UIs.

Polling-based rather than event-based on purpose: the GenTL standard
defines an interface-update event but very few producers actually fire
it. Polling at a multi-second interval is reliable and cheap.
"""

# ---------------------------------------------------------------------------
# Multi-producer enumeration
# ---------------------------------------------------------------------------

"""
    list_all_cameras(; refresh=true, timeout_ms=1000) ->
        Vector{NamedTuple{(:producer_path, :interface, :device), ...}}

Iterate every `.cti` producer found via `list_producers()`, open each in
turn, enumerate the cameras it can see, and return one entry per device
with its parent producer path tagged.

Producers that fail to load (missing dependencies, vendor lock, etc.)
are skipped with `@warn`; they don't break the walk.
"""
function list_all_cameras(; refresh::Bool = true, timeout_ms::Integer = 1000)
    out = NamedTuple{(:producer_path, :interface, :device),
        Tuple{String, GenTL.InterfaceInfo, GenTL.DeviceInfo}}[]

    for path in GenTL.list_producers()
        api = nothing
        try
            api = GenTL.load_producer(path)
            p = GenTL.Producer(api)
            try
                for entry in list_cameras(p;
                                          refresh = refresh,
                                          timeout_ms = timeout_ms)
                    push!(out, (producer_path = path,
                                interface = entry.interface,
                                device = entry.device))
                end
            finally
                close(p)
            end
        catch e
            @warn "failed to enumerate producer" path exception = e
        finally
            api === nothing || close(api)
        end
    end

    return out
end

# ---------------------------------------------------------------------------
# Hot-plug events
# ---------------------------------------------------------------------------

"""
    DeviceEvent

Emitted by `watch_devices` / `watch_all_producers` when a device appears
or disappears.

  * `kind`           — `:added` or `:removed`.
  * `producer_path`  — path to the `.cti` that reports the change. For
                       `watch_devices` (single producer) it's the path
                       of the producer being watched.
  * `interface`      — info on the parent interface.
  * `device`         — info on the device whose state changed.
  * `timestamp_ns`   — `time_ns()` at observation.
"""
struct DeviceEvent
    kind::Symbol
    producer_path::String
    interface::GenTL.InterfaceInfo
    device::GenTL.DeviceInfo
    timestamp_ns::UInt64
end

mutable struct DeviceWatch
    producer::GenTL.Producer
    producer_path::String
    channel::Channel{DeviceEvent}
    task::Task
    stop_signal::Threads.Atomic{Bool}
    interval::Float64
end

"""
    watch_devices(producer; interval=2.0, timeout_ms=500) -> Channel{DeviceEvent}

Spawn a polling `Task` that watches `producer`. Every `interval`
seconds it refreshes the interface list and (per interface) the device
list, diffs against the previous snapshot, and emits a `DeviceEvent`
for each `(producer, interface_id, device_id)` that appeared or
disappeared.

Returns the channel. Call `stop_watch!(channel)` to terminate.

The do-block variant `watch_devices(f, producer; ...)` calls `f(channel)`
inside a try/finally that guarantees `stop_watch!` runs on exit.
"""
function watch_devices(producer::GenTL.Producer;
                        interval::Real = 2.0,
                        timeout_ms::Integer = 500)
    channel = Channel{DeviceEvent}(32)
    stop_sig = Threads.Atomic{Bool}(false)
    producer_path = producer.api.path

    task = Threads.@spawn _watch_loop(producer, producer_path, channel,
        stop_sig, Float64(interval), Int(timeout_ms))

    # Stash the watch struct on the channel via a closure so stop_watch!
    # can find it without a global registry. We use a side-table keyed
    # on the channel object.
    _CHANNEL_TO_WATCH[channel] = DeviceWatch(producer, producer_path,
        channel, task, stop_sig, Float64(interval))

    return channel
end

function watch_devices(f::Function, producer::GenTL.Producer; kwargs...)
    channel = watch_devices(producer; kwargs...)
    try
        return f(channel)
    finally
        stop_watch!(channel)
    end
end

"""
    watch_all_producers(; interval=2.0, timeout_ms=500) -> Channel{DeviceEvent}

Watch every producer in `GENICAM_GENTL64_PATH` simultaneously. Spawns
one polling task per `.cti`; events from all producers funnel into a
single channel.
"""
function watch_all_producers(; interval::Real = 2.0,
                              timeout_ms::Integer = 500)
    channel = Channel{DeviceEvent}(64)
    watches = DeviceWatch[]
    for path in GenTL.list_producers()
        api = nothing
        try
            api = GenTL.load_producer(path)
            producer = GenTL.Producer(api)
            stop_sig = Threads.Atomic{Bool}(false)
            task = Threads.@spawn _watch_loop(producer, path, channel,
                stop_sig, Float64(interval), Int(timeout_ms))
            push!(watches, DeviceWatch(producer, path, channel, task,
                stop_sig, Float64(interval)))
        catch e
            @warn "watch_all_producers: skipping producer" path exception = e
            api === nothing || close(api)
        end
    end
    _CHANNEL_TO_WATCHES[channel] = watches
    return channel
end

"""
    stop_watch!(channel::Channel{DeviceEvent})

Tell every watcher feeding `channel` to exit, then close the channel.
"""
function stop_watch!(channel::Channel{DeviceEvent})
    if haskey(_CHANNEL_TO_WATCH, channel)
        w = _CHANNEL_TO_WATCH[channel]
        _shutdown_watch!(w)
        delete!(_CHANNEL_TO_WATCH, channel)
    end
    if haskey(_CHANNEL_TO_WATCHES, channel)
        for w in _CHANNEL_TO_WATCHES[channel]
            _shutdown_watch!(w)
        end
        delete!(_CHANNEL_TO_WATCHES, channel)
    end
    try; close(channel); catch; end
    return nothing
end

# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

# Side tables to find DeviceWatch from its channel (avoids storing it in
# `Channel` which doesn't carry user state).
const _CHANNEL_TO_WATCH = Dict{Channel{DeviceEvent},DeviceWatch}()
const _CHANNEL_TO_WATCHES = Dict{Channel{DeviceEvent},Vector{DeviceWatch}}()

function _watch_loop(producer::GenTL.Producer, producer_path::String,
                      channel::Channel{DeviceEvent},
                      stop_sig::Threads.Atomic{Bool},
                      interval::Float64, timeout_ms::Int)
    # State: previous (interface_id, device_id) pairs along with their
    # info structs (so :removed events can carry the right info even
    # though the device is no longer reachable).
    seen = Dict{Tuple{String,String},Tuple{GenTL.InterfaceInfo,GenTL.DeviceInfo}}()

    try
        while !stop_sig[]
            current = Dict{Tuple{String,String},
                           Tuple{GenTL.InterfaceInfo,GenTL.DeviceInfo}}()
            try
                for ifinfo in GenTL.list_interfaces(producer;
                                                     refresh = true,
                                                     timeout_ms = timeout_ms)
                    iface = GenTL.open_interface(producer, ifinfo)
                    try
                        for dev in GenTL.list_devices(iface;
                                                       refresh = true,
                                                       timeout_ms = timeout_ms)
                            current[(ifinfo.id, dev.id)] = (ifinfo, dev)
                        end
                    finally
                        close(iface)
                    end
                end
            catch e
                # Producer state can churn during enumeration — log and
                # try again next tick.
                @debug "watch loop: enumeration error" exception = e
            end

            # Diff: anything in current but not in seen → :added.
            for (k, info) in current
                haskey(seen, k) && continue
                ev = DeviceEvent(:added, producer_path,
                    info[1], info[2], time_ns())
                _try_put!(channel, ev)
            end
            # Anything in seen but not in current → :removed.
            for (k, info) in seen
                haskey(current, k) && continue
                ev = DeviceEvent(:removed, producer_path,
                    info[1], info[2], time_ns())
                _try_put!(channel, ev)
            end
            seen = current

            # Sleep with stop-signal check.
            t_end = time() + interval
            while !stop_sig[] && time() < t_end
                sleep(0.1)
            end
        end
    catch e
        @error "watch loop terminated unexpectedly" exception = e
    end
    return nothing
end

@inline function _try_put!(channel::Channel{DeviceEvent}, ev::DeviceEvent)
    try
        if Base.n_avail(channel) >= channel.sz_max
            try; take!(channel); catch; end   # drop oldest if consumer is gone
        end
        put!(channel, ev)
    catch
        # channel closed under us — fine, the loop will see stop_signal
    end
    return nothing
end

function _shutdown_watch!(w::DeviceWatch)
    w.stop_signal[] = true
    if !istaskdone(w.task)
        wait_until = time() + 3.0
        while !istaskdone(w.task) && time() < wait_until
            sleep(0.05)
        end
    end
    return w
end
