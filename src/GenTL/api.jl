"""
ccall bindings for the GenTL Producer C API (`GenTL_v1_5.h`).

A GenTL Producer is a `.cti` DLL loaded at runtime. We resolve all exported
symbols up front via `Libdl.dlsym` into a `ProducerAPI` table, then make every
`ccall` go through those function pointers. This keeps a single `ProducerAPI`
instance per loaded `.cti`, lets multiple producers coexist in the same Julia
process, and avoids hard-coding library names in `ccall` tuples.

Calling convention note: x86_64 Windows / Linux / macOS each define a
single calling convention, so the `__stdcall` / `GC_CALLTYPE` decoration
in the header has no effect on `ccall` and the bindings work identically
on all three OSes.
"""

using Libdl

# ---------------------------------------------------------------------------
# ProducerAPI — function-pointer table
# ---------------------------------------------------------------------------

const _GENTL_SYMBOLS = (
    # Library lifecycle
    :GCInitLib, :GCCloseLib, :GCGetInfo, :GCGetLastError,
    # Port access (register/XML/feature read/write)
    :GCReadPort, :GCWritePort, :GCGetPortURL, :GCGetPortInfo,
    :GCGetNumPortURLs, :GCGetPortURLInfo,
    :GCReadPortStacked, :GCWritePortStacked,
    # Events
    :GCRegisterEvent, :GCUnregisterEvent,
    :EventGetData, :EventGetDataInfo, :EventGetInfo,
    :EventFlush, :EventKill,
    # Transport Layer / Interface
    :TLOpen, :TLClose, :TLGetInfo,
    :TLGetNumInterfaces, :TLGetInterfaceID, :TLGetInterfaceInfo,
    :TLOpenInterface, :TLUpdateInterfaceList,
    :IFClose, :IFGetInfo,
    :IFGetNumDevices, :IFGetDeviceID, :IFUpdateDeviceList,
    :IFGetDeviceInfo, :IFOpenDevice,
    # Device / DataStream
    :DevGetPort, :DevGetNumDataStreams, :DevGetDataStreamID,
    :DevOpenDataStream, :DevGetInfo, :DevClose,
    :DSAnnounceBuffer, :DSAllocAndAnnounceBuffer,
    :DSFlushQueue, :DSStartAcquisition, :DSStopAcquisition,
    :DSGetInfo, :DSGetBufferID, :DSClose,
    :DSRevokeBuffer, :DSQueueBuffer, :DSGetBufferInfo,
    # GenTL v1.3+
    :DSGetBufferChunkData,
    # GenTL v1.4+
    :IFGetParentTL, :DevGetParentIF, :DSGetParentDev,
    # GenTL v1.5+
    :DSGetNumBufferParts, :DSGetBufferPartInfo,
)

mutable struct ProducerAPI
    path::String
    dlhandle::Ptr{Cvoid}
    initialized::Bool
    # function pointers (filled below)
    GCInitLib::Ptr{Cvoid}
    GCCloseLib::Ptr{Cvoid}
    GCGetInfo::Ptr{Cvoid}
    GCGetLastError::Ptr{Cvoid}
    GCReadPort::Ptr{Cvoid}
    GCWritePort::Ptr{Cvoid}
    GCGetPortURL::Ptr{Cvoid}
    GCGetPortInfo::Ptr{Cvoid}
    GCGetNumPortURLs::Ptr{Cvoid}
    GCGetPortURLInfo::Ptr{Cvoid}
    GCReadPortStacked::Ptr{Cvoid}
    GCWritePortStacked::Ptr{Cvoid}
    GCRegisterEvent::Ptr{Cvoid}
    GCUnregisterEvent::Ptr{Cvoid}
    EventGetData::Ptr{Cvoid}
    EventGetDataInfo::Ptr{Cvoid}
    EventGetInfo::Ptr{Cvoid}
    EventFlush::Ptr{Cvoid}
    EventKill::Ptr{Cvoid}
    TLOpen::Ptr{Cvoid}
    TLClose::Ptr{Cvoid}
    TLGetInfo::Ptr{Cvoid}
    TLGetNumInterfaces::Ptr{Cvoid}
    TLGetInterfaceID::Ptr{Cvoid}
    TLGetInterfaceInfo::Ptr{Cvoid}
    TLOpenInterface::Ptr{Cvoid}
    TLUpdateInterfaceList::Ptr{Cvoid}
    IFClose::Ptr{Cvoid}
    IFGetInfo::Ptr{Cvoid}
    IFGetNumDevices::Ptr{Cvoid}
    IFGetDeviceID::Ptr{Cvoid}
    IFUpdateDeviceList::Ptr{Cvoid}
    IFGetDeviceInfo::Ptr{Cvoid}
    IFOpenDevice::Ptr{Cvoid}
    DevGetPort::Ptr{Cvoid}
    DevGetNumDataStreams::Ptr{Cvoid}
    DevGetDataStreamID::Ptr{Cvoid}
    DevOpenDataStream::Ptr{Cvoid}
    DevGetInfo::Ptr{Cvoid}
    DevClose::Ptr{Cvoid}
    DSAnnounceBuffer::Ptr{Cvoid}
    DSAllocAndAnnounceBuffer::Ptr{Cvoid}
    DSFlushQueue::Ptr{Cvoid}
    DSStartAcquisition::Ptr{Cvoid}
    DSStopAcquisition::Ptr{Cvoid}
    DSGetInfo::Ptr{Cvoid}
    DSGetBufferID::Ptr{Cvoid}
    DSClose::Ptr{Cvoid}
    DSRevokeBuffer::Ptr{Cvoid}
    DSQueueBuffer::Ptr{Cvoid}
    DSGetBufferInfo::Ptr{Cvoid}
    DSGetBufferChunkData::Ptr{Cvoid}
    IFGetParentTL::Ptr{Cvoid}
    DevGetParentIF::Ptr{Cvoid}
    DSGetParentDev::Ptr{Cvoid}
    DSGetNumBufferParts::Ptr{Cvoid}
    DSGetBufferPartInfo::Ptr{Cvoid}
end

function _resolve_symbols!(api::ProducerAPI)
    h = api.dlhandle
    for sym in _GENTL_SYMBOLS
        ptr = Libdl.dlsym(h, sym; throw_error = false)
        ptr === nothing && throw(ArgumentError(
            "GenTL producer at $(api.path) is missing required symbol: $sym"))
        setfield!(api, sym, ptr::Ptr{Cvoid})
    end
    return api
end

# ---------------------------------------------------------------------------
# Wrappers — every C function gets a Julia helper that throws GenTLError on
# non-zero return codes and decodes the producer's last-error message.
# ---------------------------------------------------------------------------

"""
    last_error(api) -> (code, message)

Pull the producer's most recent error via `GCGetLastError`. Used to enrich
`GenTLError` exceptions; safe to call even on success (returns code 0 and "").
"""
function last_error(api::ProducerAPI)
    code = Ref{GC_ERROR}(GC_ERR_SUCCESS)
    sz = Ref{Csize_t}(0)
    # query needed buffer size
    ccall(api.GCGetLastError, GC_ERROR,
        (Ptr{GC_ERROR}, Ptr{UInt8}, Ptr{Csize_t}),
        code, C_NULL, sz)
    sz[] == 0 && return (code[], "")
    buf = Vector{UInt8}(undef, sz[])
    ccall(api.GCGetLastError, GC_ERROR,
        (Ptr{GC_ERROR}, Ptr{UInt8}, Ptr{Csize_t}),
        code, buf, sz)
    # Strip trailing NUL if present
    n = sz[] > 0 && buf[sz[]] == 0x00 ? sz[] - 1 : sz[]
    return (code[], String(buf[1:n]))
end

@inline function check(api::ProducerAPI, err::Integer, ctx::AbstractString = "")
    err == GC_ERR_SUCCESS && return nothing
    _, msg = last_error(api)
    throw(GenTLError(err, isempty(ctx) ? msg : "$ctx: $msg"))
end

# ----- Library lifecycle -----

gc_init_lib(api::ProducerAPI) =
    check(api, ccall(api.GCInitLib, GC_ERROR, ()), "GCInitLib")

gc_close_lib(api::ProducerAPI) =
    check(api, ccall(api.GCCloseLib, GC_ERROR, ()), "GCCloseLib")

# ----- Two-pass info readers -----

# `*GetInfo`-style functions follow a two-pass pattern: first call with a
# null buffer queries the required size, second call fills the buffer.
# Each module's GetInfo signature has a different fixed-arg prefix, so we
# can't truly write *one* helper (ccall argument types must be statically
# known); the per-shape helpers below cover all the cases we need.

function _read_info(api::ProducerAPI, funcptr::Ptr{Cvoid},
                    handle::Ptr{Cvoid}, cmd::Int32, ::Type{T}, ctx) where {T}
    dtype = Ref{Int32}(0)
    sz = Ref{Csize_t}(sizeof(T))
    val = Ref{T}()
    err = ccall(funcptr, GC_ERROR,
        (Ptr{Cvoid}, Int32, Ptr{Int32}, Ptr{Cvoid}, Ptr{Csize_t}),
        handle, cmd, dtype, val, sz)
    check(api, err, ctx)
    return val[]
end

function _read_info_string(api::ProducerAPI, funcptr::Ptr{Cvoid},
                           handle::Ptr{Cvoid}, cmd::Int32, ctx)
    dtype = Ref{Int32}(0)
    sz = Ref{Csize_t}(0)
    err = ccall(funcptr, GC_ERROR,
        (Ptr{Cvoid}, Int32, Ptr{Int32}, Ptr{UInt8}, Ptr{Csize_t}),
        handle, cmd, dtype, C_NULL, sz)
    check(api, err, ctx * " (size query)")
    sz[] == 0 && return ""
    buf = Vector{UInt8}(undef, sz[])
    err = ccall(funcptr, GC_ERROR,
        (Ptr{Cvoid}, Int32, Ptr{Int32}, Ptr{UInt8}, Ptr{Csize_t}),
        handle, cmd, dtype, buf, sz)
    check(api, err, ctx)
    n = sz[] > 0 && buf[sz[]] == 0x00 ? sz[] - 1 : sz[]
    return String(buf[1:n])
end

# ----- TL (system) -----

function tl_open(api::ProducerAPI)
    h = Ref{TL_HANDLE}(C_NULL)
    err = ccall(api.TLOpen, GC_ERROR, (Ptr{TL_HANDLE},), h)
    check(api, err, "TLOpen")
    return h[]
end

tl_close(api::ProducerAPI, h::TL_HANDLE) =
    check(api, ccall(api.TLClose, GC_ERROR, (TL_HANDLE,), h), "TLClose")

tl_get_info_string(api::ProducerAPI, h::TL_HANDLE, cmd::TL_INFO_CMD) =
    _read_info_string(api, api.TLGetInfo, h, Int32(cmd), "TLGetInfo($cmd)")

function tl_get_num_interfaces(api::ProducerAPI, h::TL_HANDLE)
    n = Ref{UInt32}(0)
    err = ccall(api.TLGetNumInterfaces, GC_ERROR,
        (TL_HANDLE, Ptr{UInt32}), h, n)
    check(api, err, "TLGetNumInterfaces")
    return n[]
end

function tl_get_interface_id(api::ProducerAPI, h::TL_HANDLE, index::Integer)
    sz = Ref{Csize_t}(0)
    err = ccall(api.TLGetInterfaceID, GC_ERROR,
        (TL_HANDLE, UInt32, Ptr{UInt8}, Ptr{Csize_t}),
        h, UInt32(index), C_NULL, sz)
    check(api, err, "TLGetInterfaceID (size query)")
    buf = Vector{UInt8}(undef, sz[])
    err = ccall(api.TLGetInterfaceID, GC_ERROR,
        (TL_HANDLE, UInt32, Ptr{UInt8}, Ptr{Csize_t}),
        h, UInt32(index), buf, sz)
    check(api, err, "TLGetInterfaceID")
    n = sz[] > 0 && buf[sz[]] == 0x00 ? sz[] - 1 : sz[]
    return String(buf[1:n])
end

function tl_get_interface_info_string(api::ProducerAPI, h::TL_HANDLE,
                                       iface_id::AbstractString,
                                       cmd::INTERFACE_INFO_CMD)
    cid = String(iface_id)
    dtype = Ref{Int32}(0)
    sz = Ref{Csize_t}(0)
    err = ccall(api.TLGetInterfaceInfo, GC_ERROR,
        (TL_HANDLE, Cstring, Int32, Ptr{Int32}, Ptr{UInt8}, Ptr{Csize_t}),
        h, cid, Int32(cmd), dtype, C_NULL, sz)
    check(api, err, "TLGetInterfaceInfo (size query)")
    sz[] == 0 && return ""
    buf = Vector{UInt8}(undef, sz[])
    err = ccall(api.TLGetInterfaceInfo, GC_ERROR,
        (TL_HANDLE, Cstring, Int32, Ptr{Int32}, Ptr{UInt8}, Ptr{Csize_t}),
        h, cid, Int32(cmd), dtype, buf, sz)
    check(api, err, "TLGetInterfaceInfo")
    n = sz[] > 0 && buf[sz[]] == 0x00 ? sz[] - 1 : sz[]
    return String(buf[1:n])
end

function tl_open_interface(api::ProducerAPI, h::TL_HANDLE,
                           iface_id::AbstractString)
    out = Ref{IF_HANDLE}(C_NULL)
    err = ccall(api.TLOpenInterface, GC_ERROR,
        (TL_HANDLE, Cstring, Ptr{IF_HANDLE}),
        h, String(iface_id), out)
    check(api, err, "TLOpenInterface($iface_id)")
    return out[]
end

function tl_update_interface_list(api::ProducerAPI, h::TL_HANDLE;
                                   timeout_ms::Integer = 1000)
    changed = Ref{UInt8}(0)
    err = ccall(api.TLUpdateInterfaceList, GC_ERROR,
        (TL_HANDLE, Ptr{UInt8}, UInt64),
        h, changed, UInt64(timeout_ms))
    check(api, err, "TLUpdateInterfaceList")
    return changed[] != 0
end

# ----- Interface -----

if_close(api::ProducerAPI, h::IF_HANDLE) =
    check(api, ccall(api.IFClose, GC_ERROR, (IF_HANDLE,), h), "IFClose")

function if_get_num_devices(api::ProducerAPI, h::IF_HANDLE)
    n = Ref{UInt32}(0)
    err = ccall(api.IFGetNumDevices, GC_ERROR,
        (IF_HANDLE, Ptr{UInt32}), h, n)
    check(api, err, "IFGetNumDevices")
    return n[]
end

function if_get_device_id(api::ProducerAPI, h::IF_HANDLE, index::Integer)
    sz = Ref{Csize_t}(0)
    err = ccall(api.IFGetDeviceID, GC_ERROR,
        (IF_HANDLE, UInt32, Ptr{UInt8}, Ptr{Csize_t}),
        h, UInt32(index), C_NULL, sz)
    check(api, err, "IFGetDeviceID (size query)")
    buf = Vector{UInt8}(undef, sz[])
    err = ccall(api.IFGetDeviceID, GC_ERROR,
        (IF_HANDLE, UInt32, Ptr{UInt8}, Ptr{Csize_t}),
        h, UInt32(index), buf, sz)
    check(api, err, "IFGetDeviceID")
    n = sz[] > 0 && buf[sz[]] == 0x00 ? sz[] - 1 : sz[]
    return String(buf[1:n])
end

function if_update_device_list(api::ProducerAPI, h::IF_HANDLE;
                                timeout_ms::Integer = 1000)
    changed = Ref{UInt8}(0)
    err = ccall(api.IFUpdateDeviceList, GC_ERROR,
        (IF_HANDLE, Ptr{UInt8}, UInt64),
        h, changed, UInt64(timeout_ms))
    check(api, err, "IFUpdateDeviceList")
    return changed[] != 0
end

function if_get_device_info_string(api::ProducerAPI, h::IF_HANDLE,
                                    dev_id::AbstractString,
                                    cmd::DEVICE_INFO_CMD)
    cid = String(dev_id)
    dtype = Ref{Int32}(0)
    sz = Ref{Csize_t}(0)
    err = ccall(api.IFGetDeviceInfo, GC_ERROR,
        (IF_HANDLE, Cstring, Int32, Ptr{Int32}, Ptr{UInt8}, Ptr{Csize_t}),
        h, cid, Int32(cmd), dtype, C_NULL, sz)
    check(api, err, "IFGetDeviceInfo (size query)")
    sz[] == 0 && return ""
    buf = Vector{UInt8}(undef, sz[])
    err = ccall(api.IFGetDeviceInfo, GC_ERROR,
        (IF_HANDLE, Cstring, Int32, Ptr{Int32}, Ptr{UInt8}, Ptr{Csize_t}),
        h, cid, Int32(cmd), dtype, buf, sz)
    check(api, err, "IFGetDeviceInfo")
    n = sz[] > 0 && buf[sz[]] == 0x00 ? sz[] - 1 : sz[]
    return String(buf[1:n])
end

function if_open_device(api::ProducerAPI, h::IF_HANDLE,
                        dev_id::AbstractString,
                        access::DEVICE_ACCESS_FLAGS = DEVICE_ACCESS_CONTROL)
    out = Ref{DEV_HANDLE}(C_NULL)
    err = ccall(api.IFOpenDevice, GC_ERROR,
        (IF_HANDLE, Cstring, Int32, Ptr{DEV_HANDLE}),
        h, String(dev_id), Int32(access), out)
    check(api, err, "IFOpenDevice($dev_id)")
    return out[]
end

# ----- Device -----

dev_close(api::ProducerAPI, h::DEV_HANDLE) =
    check(api, ccall(api.DevClose, GC_ERROR, (DEV_HANDLE,), h), "DevClose")

function dev_get_port(api::ProducerAPI, h::DEV_HANDLE)
    out = Ref{PORT_HANDLE}(C_NULL)
    err = ccall(api.DevGetPort, GC_ERROR,
        (DEV_HANDLE, Ptr{PORT_HANDLE}), h, out)
    check(api, err, "DevGetPort")
    return out[]
end

function dev_get_num_data_streams(api::ProducerAPI, h::DEV_HANDLE)
    n = Ref{UInt32}(0)
    err = ccall(api.DevGetNumDataStreams, GC_ERROR,
        (DEV_HANDLE, Ptr{UInt32}), h, n)
    check(api, err, "DevGetNumDataStreams")
    return n[]
end

function dev_get_data_stream_id(api::ProducerAPI, h::DEV_HANDLE, index::Integer)
    sz = Ref{Csize_t}(0)
    err = ccall(api.DevGetDataStreamID, GC_ERROR,
        (DEV_HANDLE, UInt32, Ptr{UInt8}, Ptr{Csize_t}),
        h, UInt32(index), C_NULL, sz)
    check(api, err, "DevGetDataStreamID (size query)")
    buf = Vector{UInt8}(undef, sz[])
    err = ccall(api.DevGetDataStreamID, GC_ERROR,
        (DEV_HANDLE, UInt32, Ptr{UInt8}, Ptr{Csize_t}),
        h, UInt32(index), buf, sz)
    check(api, err, "DevGetDataStreamID")
    n = sz[] > 0 && buf[sz[]] == 0x00 ? sz[] - 1 : sz[]
    return String(buf[1:n])
end

function dev_open_data_stream(api::ProducerAPI, h::DEV_HANDLE,
                               ds_id::AbstractString)
    out = Ref{DS_HANDLE}(C_NULL)
    err = ccall(api.DevOpenDataStream, GC_ERROR,
        (DEV_HANDLE, Cstring, Ptr{DS_HANDLE}),
        h, String(ds_id), out)
    check(api, err, "DevOpenDataStream($ds_id)")
    return out[]
end

dev_get_info_string(api::ProducerAPI, h::DEV_HANDLE, cmd::DEVICE_INFO_CMD) =
    _read_info_string(api, api.DevGetInfo, h, Int32(cmd), "DevGetInfo($cmd)")

# ----- DataStream -----

ds_close(api::ProducerAPI, h::DS_HANDLE) =
    check(api, ccall(api.DSClose, GC_ERROR, (DS_HANDLE,), h), "DSClose")

function ds_announce_buffer(api::ProducerAPI, h::DS_HANDLE,
                             pBuffer::Ptr{UInt8}, size::Integer,
                             pPrivate::Ptr{Cvoid} = C_NULL)
    out = Ref{BUFFER_HANDLE}(C_NULL)
    err = ccall(api.DSAnnounceBuffer, GC_ERROR,
        (DS_HANDLE, Ptr{UInt8}, Csize_t, Ptr{Cvoid}, Ptr{BUFFER_HANDLE}),
        h, pBuffer, Csize_t(size), pPrivate, out)
    check(api, err, "DSAnnounceBuffer")
    return out[]
end

ds_queue_buffer(api::ProducerAPI, h::DS_HANDLE, b::BUFFER_HANDLE) =
    check(api, ccall(api.DSQueueBuffer, GC_ERROR,
        (DS_HANDLE, BUFFER_HANDLE), h, b), "DSQueueBuffer")

function ds_revoke_buffer(api::ProducerAPI, h::DS_HANDLE, b::BUFFER_HANDLE)
    pbuf = Ref{Ptr{Cvoid}}(C_NULL)
    ppriv = Ref{Ptr{Cvoid}}(C_NULL)
    err = ccall(api.DSRevokeBuffer, GC_ERROR,
        (DS_HANDLE, BUFFER_HANDLE, Ptr{Ptr{Cvoid}}, Ptr{Ptr{Cvoid}}),
        h, b, pbuf, ppriv)
    check(api, err, "DSRevokeBuffer")
    return (pbuf[], ppriv[])
end

ds_flush_queue(api::ProducerAPI, h::DS_HANDLE, op::ACQ_QUEUE_TYPE) =
    check(api, ccall(api.DSFlushQueue, GC_ERROR,
        (DS_HANDLE, Int32), h, Int32(op)), "DSFlushQueue($op)")

function ds_start_acquisition(api::ProducerAPI, h::DS_HANDLE;
                               flags::ACQ_START_FLAGS = ACQ_START_FLAGS_DEFAULT,
                               num_to_acquire::Integer = GENTL_INFINITE)
    err = ccall(api.DSStartAcquisition, GC_ERROR,
        (DS_HANDLE, Int32, UInt64),
        h, Int32(flags), UInt64(num_to_acquire))
    check(api, err, "DSStartAcquisition")
    return nothing
end

function ds_stop_acquisition(api::ProducerAPI, h::DS_HANDLE;
                              flags::ACQ_STOP_FLAGS = ACQ_STOP_FLAGS_DEFAULT)
    err = ccall(api.DSStopAcquisition, GC_ERROR,
        (DS_HANDLE, Int32), h, Int32(flags))
    check(api, err, "DSStopAcquisition")
    return nothing
end

function ds_get_info(api::ProducerAPI, h::DS_HANDLE, cmd::STREAM_INFO_CMD,
                     ::Type{T}) where {T}
    _read_info(api, api.DSGetInfo, h, Int32(cmd), T, "DSGetInfo($cmd)")
end

function ds_get_buffer_info(api::ProducerAPI, h::DS_HANDLE, b::BUFFER_HANDLE,
                            cmd::BUFFER_INFO_CMD, ::Type{T}) where {T}
    dtype = Ref{Int32}(0)
    sz = Ref{Csize_t}(sizeof(T))
    val = Ref{T}()
    err = ccall(api.DSGetBufferInfo, GC_ERROR,
        (DS_HANDLE, BUFFER_HANDLE, Int32, Ptr{Int32}, Ptr{Cvoid}, Ptr{Csize_t}),
        h, b, Int32(cmd), dtype, val, sz)
    check(api, err, "DSGetBufferInfo($cmd)")
    return val[]
end

# ----- Port (register access) -----

"""
    gc_read_port(api, port, address, nbytes) -> Vector{UInt8}

Read `nbytes` from the port's register space starting at `address`.
"""
function gc_read_port(api::ProducerAPI, port::PORT_HANDLE,
                       address::Integer, nbytes::Integer)
    buf = Vector{UInt8}(undef, nbytes)
    sz = Ref{Csize_t}(nbytes)
    err = ccall(api.GCReadPort, GC_ERROR,
        (PORT_HANDLE, UInt64, Ptr{UInt8}, Ptr{Csize_t}),
        port, UInt64(address), buf, sz)
    check(api, err, "GCReadPort(addr=$(string(address; base=16)), n=$nbytes)")
    return resize!(buf, sz[])
end

function gc_write_port(api::ProducerAPI, port::PORT_HANDLE,
                       address::Integer, data::AbstractVector{UInt8})
    sz = Ref{Csize_t}(length(data))
    err = ccall(api.GCWritePort, GC_ERROR,
        (PORT_HANDLE, UInt64, Ptr{UInt8}, Ptr{Csize_t}),
        port, UInt64(address), data, sz)
    check(api, err, "GCWritePort(addr=$(string(address; base=16)))")
    return Int(sz[])
end

function gc_get_num_port_urls(api::ProducerAPI, port::PORT_HANDLE)
    n = Ref{UInt32}(0)
    err = ccall(api.GCGetNumPortURLs, GC_ERROR,
        (PORT_HANDLE, Ptr{UInt32}), port, n)
    check(api, err, "GCGetNumPortURLs")
    return n[]
end

function gc_get_port_url_info(api::ProducerAPI, port::PORT_HANDLE,
                               url_index::Integer, cmd::URL_INFO_CMD,
                               ::Type{T}) where {T}
    dtype = Ref{Int32}(0)
    sz = Ref{Csize_t}(sizeof(T))
    val = Ref{T}()
    err = ccall(api.GCGetPortURLInfo, GC_ERROR,
        (PORT_HANDLE, UInt32, Int32, Ptr{Int32}, Ptr{Cvoid}, Ptr{Csize_t}),
        port, UInt32(url_index), Int32(cmd), dtype, val, sz)
    check(api, err, "GCGetPortURLInfo($cmd)")
    return val[]
end

function gc_get_port_url_info_string(api::ProducerAPI, port::PORT_HANDLE,
                                      url_index::Integer, cmd::URL_INFO_CMD)
    dtype = Ref{Int32}(0)
    sz = Ref{Csize_t}(0)
    err = ccall(api.GCGetPortURLInfo, GC_ERROR,
        (PORT_HANDLE, UInt32, Int32, Ptr{Int32}, Ptr{UInt8}, Ptr{Csize_t}),
        port, UInt32(url_index), Int32(cmd), dtype, C_NULL, sz)
    check(api, err, "GCGetPortURLInfo($cmd) (size query)")
    sz[] == 0 && return ""
    buf = Vector{UInt8}(undef, sz[])
    err = ccall(api.GCGetPortURLInfo, GC_ERROR,
        (PORT_HANDLE, UInt32, Int32, Ptr{Int32}, Ptr{UInt8}, Ptr{Csize_t}),
        port, UInt32(url_index), Int32(cmd), dtype, buf, sz)
    check(api, err, "GCGetPortURLInfo($cmd)")
    n = sz[] > 0 && buf[sz[]] == 0x00 ? sz[] - 1 : sz[]
    return String(buf[1:n])
end

# ----- Events -----

function gc_register_event(api::ProducerAPI, src::EVENTSRC_HANDLE,
                            event_type::EVENT_TYPE)
    out = Ref{EVENT_HANDLE}(C_NULL)
    err = ccall(api.GCRegisterEvent, GC_ERROR,
        (EVENTSRC_HANDLE, Int32, Ptr{EVENT_HANDLE}),
        src, Int32(event_type), out)
    check(api, err, "GCRegisterEvent($event_type)")
    return out[]
end

gc_unregister_event(api::ProducerAPI, src::EVENTSRC_HANDLE,
                    event_type::EVENT_TYPE) =
    check(api, ccall(api.GCUnregisterEvent, GC_ERROR,
        (EVENTSRC_HANDLE, Int32), src, Int32(event_type)),
        "GCUnregisterEvent($event_type)")

event_kill(api::ProducerAPI, ev::EVENT_HANDLE) =
    check(api, ccall(api.EventKill, GC_ERROR, (EVENT_HANDLE,), ev), "EventKill")

event_flush(api::ProducerAPI, ev::EVENT_HANDLE) =
    check(api, ccall(api.EventFlush, GC_ERROR, (EVENT_HANDLE,), ev), "EventFlush")

"""
    event_get_data(api, event, ::Type{T}, timeout_ms) -> T

Block up to `timeout_ms` for the next event, then return the producer's event
payload reinterpreted as `T` (typically `EVENT_NEW_BUFFER_DATA`). Use
`GENTL_INFINITE` for `timeout_ms` to wait forever.
"""
function event_get_data(api::ProducerAPI, ev::EVENT_HANDLE, ::Type{T},
                         timeout_ms::Integer) where {T}
    sz = Ref{Csize_t}(sizeof(T))
    val = Ref{T}()
    err = ccall(api.EventGetData, GC_ERROR,
        (EVENT_HANDLE, Ptr{Cvoid}, Ptr{Csize_t}, UInt64),
        ev, val, sz, UInt64(timeout_ms))
    check(api, err, "EventGetData")
    return val[]
end

"""
    event_get_data_bytes(api, event, timeout_ms) -> Vector{UInt8}

Receive an event whose payload is a variable-length byte buffer (typically
a `EVENT_FEATURE_INVALIDATE` payload — a NUL-terminated feature name).
Two-pass: first call queries the size, then we allocate and read.
"""
function event_get_data_bytes(api::ProducerAPI, ev::EVENT_HANDLE,
                                timeout_ms::Integer)
    # First call: size query (NULL buffer). Some producers tolerate this,
    # others insist on a real read; we go straight to the read with a
    # generously-sized scratch buffer instead.
    buf = Vector{UInt8}(undef, 1024)
    sz = Ref{Csize_t}(length(buf))
    err = ccall(api.EventGetData, GC_ERROR,
        (EVENT_HANDLE, Ptr{UInt8}, Ptr{Csize_t}, UInt64),
        ev, buf, sz, UInt64(timeout_ms))
    if err == GC_ERR_BUFFER_TOO_SMALL
        resize!(buf, sz[])
        sz[] = length(buf)
        err = ccall(api.EventGetData, GC_ERROR,
            (EVENT_HANDLE, Ptr{UInt8}, Ptr{Csize_t}, UInt64),
            ev, buf, sz, UInt64(timeout_ms))
    end
    check(api, err, "EventGetData (bytes)")
    return resize!(buf, sz[])
end

"""
    ds_get_buffer_chunk_data(api, ds, buffer) -> Vector{SINGLE_CHUNK_DATA}

Two-pass query of `DSGetBufferChunkData`: first call gets the chunk count,
second fills the array. Each `SINGLE_CHUNK_DATA` carries `(ChunkID,
ChunkOffset, ChunkLength)` so the consumer can carve the payload bytes
out of the buffer's `BUFFER_INFO_BASE` region.
"""
function ds_get_buffer_chunk_data(api::ProducerAPI, ds::DS_HANDLE,
                                    buffer::BUFFER_HANDLE)
    n = Ref{Csize_t}(0)
    err = ccall(api.DSGetBufferChunkData, GC_ERROR,
        (DS_HANDLE, BUFFER_HANDLE, Ptr{SINGLE_CHUNK_DATA}, Ptr{Csize_t}),
        ds, buffer, C_NULL, n)
    check(api, err, "DSGetBufferChunkData (count)")
    n[] == 0 && return SINGLE_CHUNK_DATA[]
    chunks = Vector{SINGLE_CHUNK_DATA}(undef, n[])
    err = ccall(api.DSGetBufferChunkData, GC_ERROR,
        (DS_HANDLE, BUFFER_HANDLE, Ptr{SINGLE_CHUNK_DATA}, Ptr{Csize_t}),
        ds, buffer, chunks, n)
    check(api, err, "DSGetBufferChunkData")
    return resize!(chunks, n[])
end
