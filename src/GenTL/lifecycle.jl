"""
High-level lifecycle wrappers around the raw GenTL handles.

Each wrapper owns its handle and calls the matching `*Close` on `Base.close`
or finalisation. Children keep a reference to their parent so the parent
cannot be GC'd while a child is still alive (which would close the parent's
handle out from under us).

Hierarchy:
    Producer (TL_HANDLE)
        └─ Interface (IF_HANDLE)
              └─ Device (DEV_HANDLE)
                    └─ DataStream (DS_HANDLE)
"""

# ---------------------------------------------------------------------------
# Producer (Transport Layer system handle)
# ---------------------------------------------------------------------------

mutable struct Producer
    api::ProducerAPI
    handle::TL_HANDLE
    closed::Bool

    function Producer(api::ProducerAPI)
        h = tl_open(api)
        p = new(api, h, false)
        finalizer(_finalize_producer, p)
        return p
    end
end

function _finalize_producer(p::Producer)
    p.closed && return
    try
        tl_close(p.api, p.handle)
    catch
    end
    p.closed = true
    return
end

function Base.close(p::Producer)
    p.closed && return nothing
    tl_close(p.api, p.handle)
    p.closed = true
    return nothing
end

Base.show(io::IO, p::Producer) =
    print(io, p.closed ? "Producer(closed)" : "Producer($(basename(p.api.path)))")

producer_info(p::Producer, cmd::TL_INFO_CMD) =
    tl_get_info_string(p.api, p.handle, cmd)

# ---------------------------------------------------------------------------
# Interface
# ---------------------------------------------------------------------------

struct InterfaceInfo
    id::String
    display_name::String
    tl_type::String
end

"""
    list_interfaces(producer; refresh=true, timeout_ms=1000) -> Vector{InterfaceInfo}

Enumerate all interfaces visible to a producer. By default the producer's
internal interface list is refreshed first via `TLUpdateInterfaceList`, which
is needed on most producers before they will report any GigE/USB interfaces.
"""
function list_interfaces(p::Producer; refresh::Bool = true,
                          timeout_ms::Integer = 1000)
    refresh && tl_update_interface_list(p.api, p.handle; timeout_ms = timeout_ms)
    n = tl_get_num_interfaces(p.api, p.handle)
    out = InterfaceInfo[]
    for i in 0:(Int(n) - 1)
        id = tl_get_interface_id(p.api, p.handle, i)
        disp = ""
        ttype = ""
        try
            disp = tl_get_interface_info_string(p.api, p.handle, id,
                INTERFACE_INFO_DISPLAYNAME)
        catch
        end
        try
            ttype = tl_get_interface_info_string(p.api, p.handle, id,
                INTERFACE_INFO_TLTYPE)
        catch
        end
        push!(out, InterfaceInfo(id, disp, ttype))
    end
    return out
end

mutable struct Interface
    parent::Producer
    handle::IF_HANDLE
    id::String
    closed::Bool

    function Interface(parent::Producer, handle::IF_HANDLE, id::String)
        iface = new(parent, handle, id, false)
        finalizer(_finalize_interface, iface)
        return iface
    end
end

function _finalize_interface(iface::Interface)
    iface.closed && return
    try
        if_close(iface.parent.api, iface.handle)
    catch
    end
    iface.closed = true
    return
end

function Base.close(iface::Interface)
    iface.closed && return nothing
    if_close(iface.parent.api, iface.handle)
    iface.closed = true
    return nothing
end

Base.show(io::IO, iface::Interface) =
    print(io, iface.closed ? "Interface(closed)" : "Interface($(iface.id))")

"""
    open_interface(producer, id_or_info) -> Interface
"""
open_interface(p::Producer, id::AbstractString) =
    Interface(p, tl_open_interface(p.api, p.handle, id), String(id))

open_interface(p::Producer, info::InterfaceInfo) = open_interface(p, info.id)

# ---------------------------------------------------------------------------
# Device
# ---------------------------------------------------------------------------

struct DeviceInfo
    id::String
    vendor::String
    model::String
    display_name::String
    serial::String
    version::String
end

"""
    list_devices(interface; refresh=true, timeout_ms=1000) -> Vector{DeviceInfo}

Enumerate all devices visible on an interface. Caller may iterate the result
and pass any `DeviceInfo` to `open_device` to open it.
"""
function list_devices(iface::Interface; refresh::Bool = true,
                       timeout_ms::Integer = 1000)
    api = iface.parent.api
    refresh && if_update_device_list(api, iface.handle; timeout_ms = timeout_ms)
    n = if_get_num_devices(api, iface.handle)
    out = DeviceInfo[]
    for i in 0:(Int(n) - 1)
        id = if_get_device_id(api, iface.handle, i)
        # Each of these may legitimately fail on devices that only expose a
        # subset of identification commands, so swallow individual errors.
        vendor = _try_dev_info(api, iface.handle, id, DEVICE_INFO_VENDOR)
        model = _try_dev_info(api, iface.handle, id, DEVICE_INFO_MODEL)
        disp = _try_dev_info(api, iface.handle, id, DEVICE_INFO_DISPLAYNAME)
        serial = _try_dev_info(api, iface.handle, id, DEVICE_INFO_SERIAL_NUMBER)
        version = _try_dev_info(api, iface.handle, id, DEVICE_INFO_VERSION)
        push!(out, DeviceInfo(id, vendor, model, disp, serial, version))
    end
    return out
end

function _try_dev_info(api::ProducerAPI, ifh::IF_HANDLE, id::AbstractString,
                       cmd::DEVICE_INFO_CMD)
    try
        return if_get_device_info_string(api, ifh, id, cmd)
    catch
        return ""
    end
end

mutable struct Device
    parent::Interface
    handle::DEV_HANDLE
    id::String
    port::PORT_HANDLE
    closed::Bool

    function Device(parent::Interface, handle::DEV_HANDLE, id::String)
        api = parent.parent.api
        port = dev_get_port(api, handle)
        dev = new(parent, handle, id, port, false)
        finalizer(_finalize_device, dev)
        return dev
    end
end

function _finalize_device(d::Device)
    d.closed && return
    try
        dev_close(d.parent.parent.api, d.handle)
    catch
    end
    d.closed = true
    return
end

function Base.close(d::Device)
    d.closed && return nothing
    dev_close(d.parent.parent.api, d.handle)
    d.closed = true
    return nothing
end

Base.show(io::IO, d::Device) =
    print(io, d.closed ? "Device(closed)" : "Device($(d.id))")

"""
    open_device(interface, id_or_info; access=DEVICE_ACCESS_CONTROL) -> Device
"""
function open_device(iface::Interface, id::AbstractString;
                      access::DEVICE_ACCESS_FLAGS = DEVICE_ACCESS_CONTROL)
    api = iface.parent.api
    h = if_open_device(api, iface.handle, String(id), access)
    return Device(iface, h, String(id))
end

open_device(iface::Interface, info::DeviceInfo;
            access::DEVICE_ACCESS_FLAGS = DEVICE_ACCESS_CONTROL) =
    open_device(iface, info.id; access = access)

device_info(d::Device, cmd::DEVICE_INFO_CMD) =
    dev_get_info_string(d.parent.parent.api, d.handle, cmd)

# ---------------------------------------------------------------------------
# DataStream
# ---------------------------------------------------------------------------

mutable struct DataStream
    parent::Device
    handle::DS_HANDLE
    id::String
    closed::Bool

    function DataStream(parent::Device, handle::DS_HANDLE, id::String)
        ds = new(parent, handle, id, false)
        finalizer(_finalize_datastream, ds)
        return ds
    end
end

function _finalize_datastream(ds::DataStream)
    ds.closed && return
    try
        ds_close(ds.parent.parent.parent.api, ds.handle)
    catch
    end
    ds.closed = true
    return
end

function Base.close(ds::DataStream)
    ds.closed && return nothing
    ds_close(ds.parent.parent.parent.api, ds.handle)
    ds.closed = true
    return nothing
end

Base.show(io::IO, ds::DataStream) =
    print(io, ds.closed ? "DataStream(closed)" : "DataStream($(ds.id))")

function list_datastream_ids(d::Device)
    api = d.parent.parent.api
    n = dev_get_num_data_streams(api, d.handle)
    return [dev_get_data_stream_id(api, d.handle, i) for i in 0:(Int(n) - 1)]
end

function open_datastream(d::Device, id::Union{Nothing,AbstractString} = nothing)
    api = d.parent.parent.api
    sid = id === nothing ? first(list_datastream_ids(d)) : String(id)
    h = dev_open_data_stream(api, d.handle, sid)
    return DataStream(d, h, sid)
end

# Convenience: `producer.api` works on both ProducerAPI directly and Producer
api_of(p::Producer)     = p.api
api_of(i::Interface)    = i.parent.api
api_of(d::Device)       = d.parent.parent.api
api_of(ds::DataStream)  = ds.parent.parent.parent.api
