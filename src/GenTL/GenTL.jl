"""
    GenICam.GenTL

Julia binding for the EMVA GenICam **Transport Layer** Client Interface
(GenTL Standard v1.5). Wraps the C API exported by a vendor `.cti` producer
DLL and provides Julia-side resource management for TL/Interface/Device/
DataStream handles.

The submodule is self-contained: any other layer (GenApi node-map, high-level
Camera API) builds on top of these types and functions.
"""
module GenTL

include("types.jl")
include("api.jl")
include("producer.jl")
include("lifecycle.jl")
include("buffer.jl")

# --- Public exports --------------------------------------------------------

# Handle aliases & enums (re-export so callers can write `GenTL.DEVICE_INFO_VENDOR`)
export TL_HANDLE, IF_HANDLE, DEV_HANDLE, DS_HANDLE,
    PORT_HANDLE, BUFFER_HANDLE, EVENTSRC_HANDLE, EVENT_HANDLE,
    GenTLError, errorname,
    INFO_DATATYPE, TL_INFO_CMD, INTERFACE_INFO_CMD, DEVICE_INFO_CMD,
    DEVICE_ACCESS_FLAGS, DEVICE_ACCESS_STATUS,
    ACQ_START_FLAGS, ACQ_STOP_FLAGS, ACQ_QUEUE_TYPE,
    STREAM_INFO_CMD, BUFFER_INFO_CMD, PORT_INFO_CMD,
    URL_SCHEME_ID, URL_INFO_CMD,
    EVENT_TYPE, EVENT_INFO_CMD, EVENT_DATA_INFO_CMD,
    PAYLOADTYPE_INFO_ID, PIXELFORMAT_NAMESPACE_ID,
    EVENT_NEW_BUFFER_DATA, PORT_REGISTER_STACK_ENTRY, SINGLE_CHUNK_DATA

# Enum *values* commonly used by callers
export DEVICE_ACCESS_READONLY, DEVICE_ACCESS_CONTROL, DEVICE_ACCESS_EXCLUSIVE,
    INFO_DATATYPE_STRING, INFO_DATATYPE_INT32, INFO_DATATYPE_UINT32,
    INFO_DATATYPE_INT64, INFO_DATATYPE_UINT64, INFO_DATATYPE_BOOL8,
    INFO_DATATYPE_SIZET, INFO_DATATYPE_PTR, INFO_DATATYPE_BUFFER,
    DEVICE_INFO_ID, DEVICE_INFO_VENDOR, DEVICE_INFO_MODEL,
    DEVICE_INFO_SERIAL_NUMBER, DEVICE_INFO_DISPLAYNAME, DEVICE_INFO_VERSION,
    DEVICE_INFO_TLTYPE,
    INTERFACE_INFO_ID, INTERFACE_INFO_DISPLAYNAME, INTERFACE_INFO_TLTYPE,
    TL_INFO_ID, TL_INFO_VENDOR, TL_INFO_MODEL, TL_INFO_VERSION,
    TL_INFO_TLTYPE, TL_INFO_PATHNAME,
    STREAM_INFO_PAYLOAD_SIZE, STREAM_INFO_BUF_ANNOUNCE_MIN,
    STREAM_INFO_BUF_ALIGNMENT,
    BUFFER_INFO_BASE, BUFFER_INFO_SIZE, BUFFER_INFO_SIZE_FILLED,
    BUFFER_INFO_WIDTH, BUFFER_INFO_HEIGHT, BUFFER_INFO_PIXELFORMAT,
    BUFFER_INFO_PIXELFORMAT_NAMESPACE, BUFFER_INFO_IS_INCOMPLETE,
    BUFFER_INFO_NEW_DATA, BUFFER_INFO_PAYLOADTYPE,
    URL_INFO_URL, URL_INFO_SCHEME, URL_INFO_FILENAME, URL_INFO_FILE_SIZE,
    URL_INFO_FILE_REGISTER_ADDRESS,
    URL_SCHEME_LOCAL, URL_SCHEME_HTTP, URL_SCHEME_FILE,
    EVENT_NEW_BUFFER, EVENT_FEATURE_INVALIDATE, EVENT_FEATURE_CHANGE,
    EVENT_DATA_VALUE,
    ACQ_START_FLAGS_DEFAULT, ACQ_STOP_FLAGS_DEFAULT, ACQ_STOP_FLAGS_KILL,
    ACQ_QUEUE_INPUT_TO_OUTPUT, ACQ_QUEUE_ALL_TO_INPUT, ACQ_QUEUE_ALL_DISCARD,
    PAYLOAD_TYPE_IMAGE, PAYLOAD_TYPE_CHUNK_DATA,
    PIXELFORMAT_NAMESPACE_GEV, PIXELFORMAT_NAMESPACE_PFNC_16BIT,
    PIXELFORMAT_NAMESPACE_PFNC_32BIT,
    GENTL_INFINITE

# API surface
export ProducerAPI, list_producers, load_producer, unload_producer,
    Producer, Interface, Device, DataStream,
    InterfaceInfo, DeviceInfo,
    list_interfaces, open_interface,
    list_devices, open_device, device_info,
    list_datastream_ids, open_datastream,
    producer_info, api_of,
    last_error,
    # raw call wrappers (mostly used by buffer/event layer + GenApi)
    gc_init_lib, gc_close_lib,
    tl_open, tl_close, tl_get_info_string,
    tl_get_num_interfaces, tl_get_interface_id, tl_get_interface_info_string,
    tl_open_interface, tl_update_interface_list,
    if_close, if_get_num_devices, if_get_device_id, if_update_device_list,
    if_get_device_info_string, if_open_device,
    dev_close, dev_get_port, dev_get_num_data_streams, dev_get_data_stream_id,
    dev_open_data_stream, dev_get_info_string,
    ds_close, ds_announce_buffer, ds_queue_buffer, ds_revoke_buffer,
    ds_flush_queue, ds_start_acquisition, ds_stop_acquisition,
    ds_get_info, ds_get_buffer_info,
    gc_read_port, gc_write_port,
    gc_get_num_port_urls, gc_get_port_url_info, gc_get_port_url_info_string,
    gc_register_event, gc_unregister_event,
    event_get_data, event_get_data_bytes, event_kill, event_flush,
    ds_get_buffer_chunk_data,
    # acquisition layer
    AcquisitionBuffer, Acquisition, Frame,
    start!, stop!, next_frame!, next_frame_or_timeout, requeue!

end # module GenTL
