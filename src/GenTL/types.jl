"""
GenTL handle typedefs, error codes, info commands, and packed structs.

All values mirror `GenTL_v1_5.h` (EMVA, GenICam GenTL Subcommittee, 2015).
Underlying integer types are pinned to match the C ABI: enums use `Int32`,
sizes use `Csize_t`, pointers use `Ptr{Cvoid}`.
"""

# ---------------------------------------------------------------------------
# Handle typedefs (all `void*`)
# ---------------------------------------------------------------------------

const TL_HANDLE       = Ptr{Cvoid}
const IF_HANDLE       = Ptr{Cvoid}
const DEV_HANDLE      = Ptr{Cvoid}
const DS_HANDLE       = Ptr{Cvoid}
const PORT_HANDLE     = Ptr{Cvoid}
const BUFFER_HANDLE   = Ptr{Cvoid}
const EVENTSRC_HANDLE = Ptr{Cvoid}
const EVENT_HANDLE    = Ptr{Cvoid}

const GENTL_INVALID_HANDLE = C_NULL
const GENTL_INFINITE       = typemax(UInt64)  # 0xFFFFFFFFFFFFFFFF

# ---------------------------------------------------------------------------
# Error codes (typedef int32_t GC_ERROR)
# ---------------------------------------------------------------------------

const GC_ERROR = Int32

const GC_ERR_SUCCESS            = Int32(0)
const GC_ERR_ERROR              = Int32(-1001)
const GC_ERR_NOT_INITIALIZED    = Int32(-1002)
const GC_ERR_NOT_IMPLEMENTED    = Int32(-1003)
const GC_ERR_RESOURCE_IN_USE    = Int32(-1004)
const GC_ERR_ACCESS_DENIED      = Int32(-1005)
const GC_ERR_INVALID_HANDLE     = Int32(-1006)
const GC_ERR_INVALID_ID         = Int32(-1007)
const GC_ERR_NO_DATA            = Int32(-1008)
const GC_ERR_INVALID_PARAMETER  = Int32(-1009)
const GC_ERR_IO                 = Int32(-1010)
const GC_ERR_TIMEOUT            = Int32(-1011)
const GC_ERR_ABORT              = Int32(-1012)
const GC_ERR_INVALID_BUFFER     = Int32(-1013)
const GC_ERR_NOT_AVAILABLE      = Int32(-1014)
const GC_ERR_INVALID_ADDRESS    = Int32(-1015)
const GC_ERR_BUFFER_TOO_SMALL   = Int32(-1016)
const GC_ERR_INVALID_INDEX      = Int32(-1017)
const GC_ERR_PARSING_CHUNK_DATA = Int32(-1018)
const GC_ERR_INVALID_VALUE      = Int32(-1019)
const GC_ERR_RESOURCE_EXHAUSTED = Int32(-1020)
const GC_ERR_OUT_OF_MEMORY      = Int32(-1021)
const GC_ERR_BUSY               = Int32(-1022)

const _ERROR_NAMES = Dict{Int32,String}(
    GC_ERR_SUCCESS            => "GC_ERR_SUCCESS",
    GC_ERR_ERROR              => "GC_ERR_ERROR",
    GC_ERR_NOT_INITIALIZED    => "GC_ERR_NOT_INITIALIZED",
    GC_ERR_NOT_IMPLEMENTED    => "GC_ERR_NOT_IMPLEMENTED",
    GC_ERR_RESOURCE_IN_USE    => "GC_ERR_RESOURCE_IN_USE",
    GC_ERR_ACCESS_DENIED      => "GC_ERR_ACCESS_DENIED",
    GC_ERR_INVALID_HANDLE     => "GC_ERR_INVALID_HANDLE",
    GC_ERR_INVALID_ID         => "GC_ERR_INVALID_ID",
    GC_ERR_NO_DATA            => "GC_ERR_NO_DATA",
    GC_ERR_INVALID_PARAMETER  => "GC_ERR_INVALID_PARAMETER",
    GC_ERR_IO                 => "GC_ERR_IO",
    GC_ERR_TIMEOUT            => "GC_ERR_TIMEOUT",
    GC_ERR_ABORT              => "GC_ERR_ABORT",
    GC_ERR_INVALID_BUFFER     => "GC_ERR_INVALID_BUFFER",
    GC_ERR_NOT_AVAILABLE      => "GC_ERR_NOT_AVAILABLE",
    GC_ERR_INVALID_ADDRESS    => "GC_ERR_INVALID_ADDRESS",
    GC_ERR_BUFFER_TOO_SMALL   => "GC_ERR_BUFFER_TOO_SMALL",
    GC_ERR_INVALID_INDEX      => "GC_ERR_INVALID_INDEX",
    GC_ERR_PARSING_CHUNK_DATA => "GC_ERR_PARSING_CHUNK_DATA",
    GC_ERR_INVALID_VALUE      => "GC_ERR_INVALID_VALUE",
    GC_ERR_RESOURCE_EXHAUSTED => "GC_ERR_RESOURCE_EXHAUSTED",
    GC_ERR_OUT_OF_MEMORY      => "GC_ERR_OUT_OF_MEMORY",
    GC_ERR_BUSY               => "GC_ERR_BUSY",
)

"""
    errorname(code) -> String

Look up the symbolic name (`"GC_ERR_TIMEOUT"` etc.) of a `GC_ERROR`
return code. Returns `"GC_ERR_UNKNOWN(<code>)"` for codes outside the
spec'd range.
"""
errorname(code::Integer) = get(_ERROR_NAMES, Int32(code), "GC_ERR_UNKNOWN($code)")

"""
    GenTLError <: Exception

Wraps a non-zero return from any GenTL function. Carries the numeric
`code`, the spec'd `name` (e.g. `"GC_ERR_TIMEOUT"`), and the producer's
last-error message (from `GCGetLastError`). Every `ccall` that returns
a `GC_ERROR` is checked and a `GenTLError` is thrown on non-zero.
"""
struct GenTLError <: Exception
    code::Int32
    name::String
    message::String
end

function GenTLError(code::Integer, message::AbstractString = "")
    GenTLError(Int32(code), errorname(code), String(message))
end

function Base.showerror(io::IO, e::GenTLError)
    print(io, "GenTLError(", e.code, ", ", e.name, ")")
    isempty(e.message) || print(io, ": ", e.message)
end

# ---------------------------------------------------------------------------
# INFO_DATATYPE
# ---------------------------------------------------------------------------

@enum INFO_DATATYPE::Int32 begin
    INFO_DATATYPE_UNKNOWN    = 0
    INFO_DATATYPE_STRING     = 1
    INFO_DATATYPE_STRINGLIST = 2
    INFO_DATATYPE_INT16      = 3
    INFO_DATATYPE_UINT16     = 4
    INFO_DATATYPE_INT32      = 5
    INFO_DATATYPE_UINT32     = 6
    INFO_DATATYPE_INT64      = 7
    INFO_DATATYPE_UINT64     = 8
    INFO_DATATYPE_FLOAT64    = 9
    INFO_DATATYPE_PTR        = 10
    INFO_DATATYPE_BOOL8      = 11
    INFO_DATATYPE_SIZET      = 12
    INFO_DATATYPE_BUFFER     = 13
    INFO_DATATYPE_PTRDIFF    = 14
end

# ---------------------------------------------------------------------------
# Info command enums
# ---------------------------------------------------------------------------

@enum TL_INFO_CMD::Int32 begin
    TL_INFO_ID              = 0
    TL_INFO_VENDOR          = 1
    TL_INFO_MODEL           = 2
    TL_INFO_VERSION         = 3
    TL_INFO_TLTYPE          = 4
    TL_INFO_NAME            = 5
    TL_INFO_PATHNAME        = 6
    TL_INFO_DISPLAYNAME     = 7
    TL_INFO_CHAR_ENCODING   = 8
    TL_INFO_GENTL_VER_MAJOR = 9
    TL_INFO_GENTL_VER_MINOR = 10
end

@enum INTERFACE_INFO_CMD::Int32 begin
    INTERFACE_INFO_ID          = 0
    INTERFACE_INFO_DISPLAYNAME = 1
    INTERFACE_INFO_TLTYPE      = 2
end

@enum DEVICE_INFO_CMD::Int32 begin
    DEVICE_INFO_ID                  = 0
    DEVICE_INFO_VENDOR              = 1
    DEVICE_INFO_MODEL               = 2
    DEVICE_INFO_TLTYPE              = 3
    DEVICE_INFO_DISPLAYNAME         = 4
    DEVICE_INFO_ACCESS_STATUS       = 5
    DEVICE_INFO_USER_DEFINED_NAME   = 6
    DEVICE_INFO_SERIAL_NUMBER       = 7
    DEVICE_INFO_VERSION             = 8
    DEVICE_INFO_TIMESTAMP_FREQUENCY = 9
end

@enum DEVICE_ACCESS_FLAGS::Int32 begin
    DEVICE_ACCESS_UNKNOWN   = 0
    DEVICE_ACCESS_NONE      = 1
    DEVICE_ACCESS_READONLY  = 2
    DEVICE_ACCESS_CONTROL   = 3
    DEVICE_ACCESS_EXCLUSIVE = 4
end

@enum DEVICE_ACCESS_STATUS::Int32 begin
    DEVICE_ACCESS_STATUS_UNKNOWN        = 0
    DEVICE_ACCESS_STATUS_READWRITE      = 1
    DEVICE_ACCESS_STATUS_READONLY       = 2
    DEVICE_ACCESS_STATUS_NOACCESS       = 3
    DEVICE_ACCESS_STATUS_BUSY           = 4
    DEVICE_ACCESS_STATUS_OPEN_READWRITE = 5
    DEVICE_ACCESS_STATUS_OPEN_READ      = 6
end

@enum ACQ_START_FLAGS::Int32 begin
    ACQ_START_FLAGS_DEFAULT = 0
end

@enum ACQ_STOP_FLAGS::Int32 begin
    ACQ_STOP_FLAGS_DEFAULT = 0
    ACQ_STOP_FLAGS_KILL    = 1
end

@enum ACQ_QUEUE_TYPE::Int32 begin
    ACQ_QUEUE_INPUT_TO_OUTPUT   = 0
    ACQ_QUEUE_OUTPUT_DISCARD    = 1
    ACQ_QUEUE_ALL_TO_INPUT      = 2
    ACQ_QUEUE_UNQUEUED_TO_INPUT = 3
    ACQ_QUEUE_ALL_DISCARD       = 4
end

@enum STREAM_INFO_CMD::Int32 begin
    STREAM_INFO_ID                  = 0
    STREAM_INFO_NUM_DELIVERED       = 1
    STREAM_INFO_NUM_UNDERRUN        = 2
    STREAM_INFO_NUM_ANNOUNCED       = 3
    STREAM_INFO_NUM_QUEUED          = 4
    STREAM_INFO_NUM_AWAIT_DELIVERY  = 5
    STREAM_INFO_NUM_STARTED         = 6
    STREAM_INFO_PAYLOAD_SIZE        = 7
    STREAM_INFO_IS_GRABBING         = 8
    STREAM_INFO_DEFINES_PAYLOADSIZE = 9
    STREAM_INFO_TLTYPE              = 10
    STREAM_INFO_NUM_CHUNKS_MAX      = 11
    STREAM_INFO_BUF_ANNOUNCE_MIN    = 12
    STREAM_INFO_BUF_ALIGNMENT       = 13
end

@enum BUFFER_INFO_CMD::Int32 begin
    BUFFER_INFO_BASE                       = 0
    BUFFER_INFO_SIZE                       = 1
    BUFFER_INFO_USER_PTR                   = 2
    BUFFER_INFO_TIMESTAMP                  = 3
    BUFFER_INFO_NEW_DATA                   = 4
    BUFFER_INFO_IS_QUEUED                  = 5
    BUFFER_INFO_IS_ACQUIRING               = 6
    BUFFER_INFO_IS_INCOMPLETE              = 7
    BUFFER_INFO_TLTYPE                     = 8
    BUFFER_INFO_SIZE_FILLED                = 9
    BUFFER_INFO_WIDTH                      = 10
    BUFFER_INFO_HEIGHT                     = 11
    BUFFER_INFO_XOFFSET                    = 12
    BUFFER_INFO_YOFFSET                    = 13
    BUFFER_INFO_XPADDING                   = 14
    BUFFER_INFO_YPADDING                   = 15
    BUFFER_INFO_FRAMEID                    = 16
    BUFFER_INFO_IMAGEPRESENT               = 17
    BUFFER_INFO_IMAGEOFFSET                = 18
    BUFFER_INFO_PAYLOADTYPE                = 19
    BUFFER_INFO_PIXELFORMAT                = 20
    BUFFER_INFO_PIXELFORMAT_NAMESPACE      = 21
    BUFFER_INFO_DELIVERED_IMAGEHEIGHT      = 22
    BUFFER_INFO_DELIVERED_CHUNKPAYLOADSIZE = 23
    BUFFER_INFO_CHUNKLAYOUTID              = 24
    BUFFER_INFO_FILENAME                   = 25
    BUFFER_INFO_PIXEL_ENDIANNESS           = 26
    BUFFER_INFO_DATA_SIZE                  = 27
    BUFFER_INFO_TIMESTAMP_NS               = 28
    BUFFER_INFO_DATA_LARGER_THAN_BUFFER    = 29
    BUFFER_INFO_CONTAINS_CHUNKDATA         = 30
end

@enum PORT_INFO_CMD::Int32 begin
    PORT_INFO_ID            = 0
    PORT_INFO_VENDOR        = 1
    PORT_INFO_MODEL         = 2
    PORT_INFO_TLTYPE        = 3
    PORT_INFO_MODULE        = 4
    PORT_INFO_LITTLE_ENDIAN = 5
    PORT_INFO_BIG_ENDIAN    = 6
    PORT_INFO_ACCESS_READ   = 7
    PORT_INFO_ACCESS_WRITE  = 8
    PORT_INFO_ACCESS_NA     = 9
    PORT_INFO_ACCESS_NI     = 10
    PORT_INFO_VERSION       = 11
    PORT_INFO_PORTNAME      = 12
end

@enum URL_SCHEME_ID::Int32 begin
    URL_SCHEME_LOCAL = 0
    URL_SCHEME_HTTP  = 1
    URL_SCHEME_FILE  = 2
end

@enum URL_INFO_CMD::Int32 begin
    URL_INFO_URL                   = 0
    URL_INFO_SCHEMA_VER_MAJOR      = 1
    URL_INFO_SCHEMA_VER_MINOR      = 2
    URL_INFO_FILE_VER_MAJOR        = 3
    URL_INFO_FILE_VER_MINOR        = 4
    URL_INFO_FILE_VER_SUBMINOR     = 5
    URL_INFO_FILE_SHA1_HASH        = 6
    URL_INFO_FILE_REGISTER_ADDRESS = 7
    URL_INFO_FILE_SIZE             = 8
    URL_INFO_SCHEME                = 9
    URL_INFO_FILENAME              = 10
end

@enum EVENT_TYPE::Int32 begin
    EVENT_ERROR              = 0
    EVENT_NEW_BUFFER         = 1
    EVENT_FEATURE_INVALIDATE = 2
    EVENT_FEATURE_CHANGE     = 3
    EVENT_REMOTE_DEVICE      = 4
    EVENT_MODULE             = 5
end

@enum EVENT_INFO_CMD::Int32 begin
    EVENT_EVENT_TYPE         = 0
    EVENT_NUM_IN_QUEUE       = 1
    EVENT_NUM_FIRED          = 2
    EVENT_SIZE_MAX           = 3
    EVENT_INFO_DATA_SIZE_MAX = 4
end

@enum EVENT_DATA_INFO_CMD::Int32 begin
    EVENT_DATA_ID    = 0
    EVENT_DATA_VALUE = 1
    EVENT_DATA_NUMID = 2
end

@enum PAYLOADTYPE_INFO_ID::Int32 begin
    PAYLOAD_TYPE_UNKNOWN         = 0
    PAYLOAD_TYPE_IMAGE           = 1
    PAYLOAD_TYPE_RAW_DATA        = 2
    PAYLOAD_TYPE_FILE            = 3
    PAYLOAD_TYPE_CHUNK_DATA      = 4
    PAYLOAD_TYPE_JPEG            = 5
    PAYLOAD_TYPE_JPEG2000        = 6
    PAYLOAD_TYPE_H264            = 7
    PAYLOAD_TYPE_CHUNK_ONLY      = 8
    PAYLOAD_TYPE_DEVICE_SPECIFIC = 9
    PAYLOAD_TYPE_MULTI_PART      = 10
end

@enum PIXELFORMAT_NAMESPACE_ID::Int32 begin
    PIXELFORMAT_NAMESPACE_UNKNOWN    = 0
    PIXELFORMAT_NAMESPACE_GEV        = 1
    PIXELFORMAT_NAMESPACE_IIDC       = 2
    PIXELFORMAT_NAMESPACE_PFNC_16BIT = 3
    PIXELFORMAT_NAMESPACE_PFNC_32BIT = 4
end

@enum TL_CHAR_ENCODING::Int32 begin
    TL_CHAR_ENCODING_ASCII = 0
    TL_CHAR_ENCODING_UTF8  = 1
end

# ---------------------------------------------------------------------------
# Packed structs
#
# All three are declared with `#pragma pack(push, 1)` in the C header, but on
# x86_64 every field is naturally 8-byte aligned anyway, so the default Julia
# layout matches the C ABI.
# ---------------------------------------------------------------------------

struct EVENT_NEW_BUFFER_DATA
    BufferHandle::BUFFER_HANDLE
    pUserPointer::Ptr{Cvoid}
end

struct PORT_REGISTER_STACK_ENTRY
    Address::UInt64
    pBuffer::Ptr{Cvoid}
    Size::Csize_t
end

struct SINGLE_CHUNK_DATA
    ChunkID::UInt64
    ChunkOffset::Cptrdiff_t
    ChunkLength::Csize_t
end
