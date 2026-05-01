"""
Load a camera's GenApi XML node-map description from the remote device port.

Producers expose the XML via `GCGetPortURL` / `GCGetNumPortURLs` /
`GCGetPortURLInfo`. The format is typically a "local" URL pointing into the
device's own register map:

    "Local:<filename>;<addr-hex>;<length-hex>"      (legacy GenICam syntax)
    "local:///<filename>?addr=0xNNNN&size=0xNNNN"   (URI syntax)

We then read those bytes via `GCReadPort` and, if the filename ends in
`.zip`, unzip the first entry.

Currently only the `URL_SCHEME_LOCAL` variant is supported. HTTP and
FILE schemes throw `NotImplementedYet`.
"""

using .GenTL
using ZipFile

struct NotImplementedYet <: Exception
    message::String
end
Base.showerror(io::IO, e::NotImplementedYet) =
    print(io, "NotImplementedYet: ", e.message)

"""
    load_xml(port_handle, api) -> String

Read the producer's first port URL, fetch the XML bytes, decompress if
needed, and return the XML document as a `String`.
"""
function load_xml(port::PORT_HANDLE, api::ProducerAPI)
    n = gc_get_num_port_urls(api, port)
    n == 0 && throw(ArgumentError("port has no URLs"))

    # Try each URL until one yields a usable XML; in practice producers only
    # advertise one URL but the standard allows multiples.
    last_err = nothing
    for idx in 0:(Int(n) - 1)
        try
            return _load_xml_at(api, port, idx)
        catch e
            last_err = e
        end
    end
    throw(last_err)
end

function _load_xml_at(api::ProducerAPI, port::PORT_HANDLE, idx::Integer)
    scheme = _try_get_scheme(api, port, idx)
    if scheme === URL_SCHEME_HTTP
        throw(NotImplementedYet(
            "HTTP-hosted camera XML (URL_SCHEME_HTTP) is not yet supported"))
    elseif scheme === URL_SCHEME_FILE
        throw(NotImplementedYet(
            "File-hosted camera XML (URL_SCHEME_FILE) is not yet supported"))
    end
    # Either URL_SCHEME_LOCAL or scheme query unsupported (older producers);
    # in both cases attempt to parse the URL string.

    filename, addr, size = _resolve_local_xml_location(api, port, idx)
    bytes = gc_read_port(api, port, addr, Int(size))

    # Detect ZIP by magic bytes regardless of the advertised filename. Some
    # producers (e.g. MATRIX VISION mvBlueFOX3 over USB3) ship ZIP-compressed
    # XML but report the inner `.xml` name in URL_INFO_FILENAME.
    if _is_zip(bytes) || endswith(lowercase(filename), ".zip")
        return _decompress_first_xml(bytes, filename)
    else
        return String(bytes)
    end
end

@inline function _is_zip(bytes::AbstractVector{UInt8})
    length(bytes) >= 4 || return false
    # PK\x03\x04 = local file header; PK\x05\x06 = empty archive end record
    @inbounds bytes[1] == UInt8('P') && bytes[2] == UInt8('K') &&
        (bytes[3] == 0x03 || bytes[3] == 0x05) &&
        (bytes[4] == 0x04 || bytes[4] == 0x06)
end

function _try_get_scheme(api::ProducerAPI, port::PORT_HANDLE, idx::Integer)
    try
        s = gc_get_port_url_info(api, port, idx, URL_INFO_SCHEME, Int32)
        return URL_SCHEME_ID(s)
    catch
        return nothing  # producer does not implement URL_INFO_SCHEME (pre-v1.5)
    end
end

"""
    _resolve_local_xml_location(api, port, idx) -> (filename, addr, size)

Determine where in the register map the XML lives. Prefers the explicit
v1.5 query commands (`URL_INFO_FILENAME` / `URL_INFO_FILE_REGISTER_ADDRESS`
/ `URL_INFO_FILE_SIZE`) and falls back to parsing the URL string for older
producers.
"""
function _resolve_local_xml_location(api::ProducerAPI, port::PORT_HANDLE,
                                      idx::Integer)
    # Preferred path: direct v1.5 fields
    fname = ""
    addr = UInt64(0)
    size = UInt64(0)
    have_explicit = false
    try
        fname = gc_get_port_url_info_string(api, port, idx, URL_INFO_FILENAME)
        addr = gc_get_port_url_info(api, port, idx,
            URL_INFO_FILE_REGISTER_ADDRESS, UInt64)
        size = gc_get_port_url_info(api, port, idx, URL_INFO_FILE_SIZE, UInt64)
        have_explicit = !isempty(fname) && size > 0
    catch
        have_explicit = false
    end
    have_explicit && return (fname, addr, size)

    # Fallback: parse the URL string
    url = gc_get_port_url_info_string(api, port, idx, URL_INFO_URL)
    isempty(url) && error("port URL is empty and explicit fields unavailable")
    return _parse_local_url(url)
end

"""
    _parse_local_url(url) -> (filename, addr, size)

Parse the two GenICam local-URL conventions:

Legacy: `Local:Mikrotron_MC4080.xml;F0F00000;C16`
URI:    `local:///path/file.xml?addr=0xF0F00000&size=0xC16`

Hex strings may or may not carry an `0x` prefix.
"""
function _parse_local_url(url::AbstractString)
    s = String(url)

    # URI form: local:///<filename>?addr=...&size=...
    m = match(r"^[Ll]ocal:/+([^?]+)\?(.*)$", s)
    if m !== nothing
        filename = String(m.captures[1])
        query = String(m.captures[2])
        addr = _hex(_query_param(query, "addr"))
        size = _hex(_query_param(query, "size"))
        return (filename, addr, size)
    end

    # Legacy form: Local:<filename>;<addr>;<size>
    m = match(r"^[Ll]ocal:([^;]+);([0-9A-Fa-fxX]+);([0-9A-Fa-fxX]+)$", s)
    if m !== nothing
        filename = String(m.captures[1])
        addr = _hex(String(m.captures[2]))
        size = _hex(String(m.captures[3]))
        return (filename, addr, size)
    end

    throw(ArgumentError("cannot parse GenTL local URL: $(repr(s))"))
end

function _query_param(query::AbstractString, key::AbstractString)
    for pair in split(query, '&'; keepempty = false)
        kv = split(pair, '='; limit = 2)
        length(kv) == 2 && String(kv[1]) == key && return String(kv[2])
    end
    throw(ArgumentError("query parameter '$key' not found in: $query"))
end

function _hex(s::AbstractString)
    t = startswith(lowercase(s), "0x") ? s[3:end] : s
    return parse(UInt64, t; base = 16)
end

function _decompress_first_xml(zip_bytes::Vector{UInt8}, hint::AbstractString)
    io = IOBuffer(zip_bytes)
    reader = ZipFile.Reader(io)
    try
        for f in reader.files
            if endswith(lowercase(f.name), ".xml")
                return read(f, String)
            end
        end
        # No .xml inside; return first entry verbatim — some producers mis-name
        isempty(reader.files) && error("zip archive '$hint' is empty")
        return read(first(reader.files), String)
    finally
        close(reader)
    end
end
