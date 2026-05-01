```@meta
CurrentModule = GenICam
```

# Hot-plug detection

Two related needs:

  * **One-shot enumeration across producers** — "show me every camera
    on this machine, no matter which vendor". Use
    [`list_all_cameras`](@ref).
  * **Live device-list monitoring** — "tell me when somebody plugs or
    unplugs a camera". Use [`watch_devices`](@ref) (single producer)
    or [`watch_all_producers`](@ref) (every installed `.cti`).

Both are polling-based on purpose: GenTL standardises an interface-
update event (`TLUpdateInterfaceList`-driven), but very few producers
actually fire it. A 2-second poll is reliable across vendors, cheap,
and good enough for a UI device list.

## list_all_cameras

```julia
list_all_cameras()
# Vector{NamedTuple{(:producer_path, :interface, :device), ...}}:
#   (producer_path = ".../Balluff/.../mvGenTLProducer.cti",
#    interface     = InterfaceInfo(id="...USB...", tl_type="U3V"),
#    device        = DeviceInfo(id="VID164C_PID5533_F0700035",
#                               vendor="MATRIX VISION GmbH",
#                               model="mvBlueFOX3-1013C", ...))
```

This walks every `.cti` returned by [`list_producers`](@ref), opens
each transiently, enumerates its visible cameras, and returns every
device tagged with the producer that reported it. Producers that fail
to load are skipped with `@warn`; they don't break the walk.

Useful at app startup to discover what's available. The returned tuples
are pickled enough that you can serialize them, hand to a GUI, etc.

## watch_devices

```julia
watch_devices(producer; interval = 2.0, timeout_ms = 500) do channel
    for event in channel
        if event.kind === :added
            println("plugged in: ", event.device.model)
        else
            println("unplugged: ", event.device.model)
        end
    end
end
```

The do-block variant guarantees [`stop_watch!`](@ref) runs on exit.
Outside a do-block:

```julia
ch = watch_devices(producer; interval = 2.0)
# ... later ...
stop_watch!(ch)
```

### What you get

The watcher emits one `:added` event per device that *appears* (newly
visible since the previous poll) and one `:removed` event per device
that *disappears*. On the very first poll, every currently-attached
device counts as "newly visible" — so you'll see one `:added` per
existing camera at start-up.

The channel has a small bounded capacity (default 32). If your consumer
is slow and the queue fills, the oldest event is dropped to make room
— consistent with the streaming-API's `DROP_OLDEST` policy. Don't rely
on observing every event; rely on a periodic re-enumeration via
[`list_all_cameras`](@ref) for ground truth.

### Polling cadence

The `interval` arg is the wall time between full enumerations. Two
seconds is a reasonable default — short enough to feel responsive,
long enough not to hammer the producer. For latency-sensitive use
cases you can drop to 0.5 s; below that some producers stutter or the
device list flickers under load.

`timeout_ms` is the per-call cap on `tl_update_interface_list` /
`if_update_device_list`. 500 ms is plenty even on slow USB / GigE.

## watch_all_producers

Same idea, fanning out across every installed producer:

```julia
ch = watch_all_producers(; interval = 2.0)
for event in ch
    println(event.kind, " ", event.device.model,
            " under ", basename(event.producer_path))
end
stop_watch!(ch)
```

One polling task per producer, all funnelling into a single channel.
`stop_watch!` shuts every task down and closes the channel.

See [API reference](api.md) for full signatures of `list_all_cameras`,
`watch_devices`, `watch_all_producers`, `stop_watch!`, and
`DeviceEvent`.
