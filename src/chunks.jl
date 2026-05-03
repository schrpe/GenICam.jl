"""
GenICam chunk-data support.

Many machine-vision cameras can append per-frame metadata to each image:
the exposure time used at capture, an incrementing FrameID, a hardware
timestamp, the count of triggered events, etc. The mechanism is GenApi's
"chunk data" — each metadata feature has a `<ChunkID>` in the camera XML
matching the chunk identifier the producer reports via
`DSGetBufferChunkData` after each acquired buffer.

Workflow:

```julia
enable_chunks!(cam, [:Timestamp, :FrameID, :ExposureTime])
img  = grab(cam)                    # frame.chunks is now populated
ts   = img_chunks(img)[:Timestamp]
fid  = img_chunks(img)[:FrameID]
disable_chunks!(cam)
```

`enable_chunks!` activates `ChunkModeActive` and selects each named
chunk. `decode_chunks!` is called automatically inside `grab` and
`stream`'s decoded path; you can also call it on an arbitrary `Frame`
the streaming layer hands you when `decode = false`.
"""

# ---------------------------------------------------------------------------
# Chunk binding cache
# ---------------------------------------------------------------------------

"""
    ChunkBinding

Resolved (chunk_id, decoder, name) triple cached on the `Camera` so
per-frame chunk decoding doesn't have to walk the nodemap each time.
"""
struct ChunkBinding
    name::Symbol
    chunk_id::UInt64
    node::GenApi.Node
end

"""
    ChunkBindings

Pre-split bindings cache stored on `cam.chunk_bindings` after
[`enable_chunks!`](@ref). Holds the two binding flavours separately so
`decode_chunks!` doesn't have to filter the full list per frame — at
30+ fps that filter showed up as two `Vector{ChunkBinding}` allocations
per frame on the streaming hot path.

  * `canonical` — bindings whose nodes carry a `<ChunkID>` (`chunk_id != 0`).
    Decoded by carving bytes out of the buffer payload via
    `DSGetBufferChunkData`.
  * `virtual`   — producer-virtual bindings (`chunk_id == 0`, e.g.
    mvBlueFOX). Decoded by reading through the regular nodemap accessor.
"""
struct ChunkBindings
    canonical::Vector{ChunkBinding}
    virtual::Vector{ChunkBinding}
end

Base.isempty(cb::ChunkBindings) = isempty(cb.canonical) && isempty(cb.virtual)

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

"""
    chunk_features(cam) -> Vector{Symbol}

List the names of every chunk-eligible node — either nodes carrying a
GenApi `<ChunkID>` (canonical mechanism) or "Chunk*"-prefixed feature
nodes that some vendors (notably MATRIX VISION mvBlueFOX) expose via a
producer-side virtual port instead of the `<ChunkID>` declaration.

Excludes the control nodes `ChunkModeActive`, `ChunkSelector`, and
`ChunkEnable` themselves.
"""
function chunk_features(cam::Camera)
    out = Set{Symbol}()
    for n in values(cam.nodemap.nodes)
        # Skip the control / config nodes
        n.name in ("ChunkModeActive", "ChunkSelector", "ChunkEnable") && continue
        if n.meta.chunk_id != 0
            push!(out, Symbol(n.name))
        elseif startswith(n.name, "Chunk") && GenApi.is_feature(n)
            push!(out, Symbol(n.name))
        end
    end
    return sort!(collect(out))
end

# ---------------------------------------------------------------------------
# Enable / disable
# ---------------------------------------------------------------------------

"""
    enable_chunks!(cam, names::Vector{Symbol})

Turn on chunk mode and select each named chunk. The order is important
on most cameras: `ChunkModeActive` must go first, then for each name we
set `ChunkSelector = name` and `ChunkEnable = true`. Caches the resolved
bindings on `cam.chunk_bindings` so `decode_chunks!` is fast.

Two binding flavours are recognised:

  * **Canonical**: the chunk-bearing node carries a `<ChunkID>`. The
    binding stores that ID and `decode_chunks!` carves the chunk out of
    the buffer payload via `DSGetBufferChunkData`.
  * **Producer-virtual** (mvBlueFOX-style): the chunk feature has no
    `<ChunkID>` but its register lives on a producer-managed virtual
    port (e.g. `ImageInfoPort`). The binding stores ID 0 and
    `decode_chunks!` reads the value through the regular nodemap
    accessor — the producer routes the read to the buffer's metadata.
"""
function enable_chunks!(cam::Camera, names::Vector{Symbol})
    haskey(cam.nodemap, "ChunkModeActive") || throw(ArgumentError(
        "camera does not expose ChunkModeActive"))

    set_feature!(cam, :ChunkModeActive, true)

    canonical = ChunkBinding[]
    virtual = ChunkBinding[]
    for nm in names
        # The selector entry corresponds to the chunk name with the
        # "Chunk" prefix usually stripped — most cameras use the bare
        # selector name (e.g. ChunkSelector = "ExposureTime") to enable
        # a node whose internal name is "ChunkExposureTime".
        sel = String(nm)
        startswith(sel, "Chunk") && (sel = sel[6:end])
        # Selector / Enable writes are best-effort: some cameras only
        # support a single `Image` selector and bundle everything (mv
        # mvBlueFOX3 e.g.). A failure here is not fatal — we can still
        # read the chunk feature directly through the nodemap.
        try
            set_feature!(cam, :ChunkSelector, sel)
            set_feature!(cam, :ChunkEnable, true)
        catch
        end

        # Resolve the chunk-bearing node — preferred lookup is the
        # "Chunk<Name>" internal node, falling back to the bare name.
        node = nothing
        for candidate in (string("Chunk", String(nm)), String(nm))
            if haskey(cam.nodemap, candidate)
                node = cam.nodemap[candidate]
                break
            end
        end
        node === nothing && continue
        binding = ChunkBinding(nm, node.meta.chunk_id, node)
        # ChunkID == 0 means producer-virtual binding (read via nodemap);
        # otherwise it's the canonical buffer-payload binding. Splitting
        # here keeps `decode_chunks!` allocation-free per frame.
        if binding.chunk_id != 0
            push!(canonical, binding)
        else
            push!(virtual, binding)
        end
    end

    cam.chunk_bindings = ChunkBindings(canonical, virtual)
    return cam
end

"""
    disable_chunks!(cam)

Turn off chunk mode and clear the binding cache.
"""
function disable_chunks!(cam::Camera)
    if haskey(cam.nodemap, "ChunkModeActive")
        try
            set_feature!(cam, :ChunkModeActive, false)
        catch
        end
    end
    cam.chunk_bindings = nothing
    return cam
end

# ---------------------------------------------------------------------------
# Decode
# ---------------------------------------------------------------------------

"""
    decode_chunks!(frame, cam) -> frame

If `frame` carries chunk data (`BUFFER_INFO_CONTAINS_CHUNKDATA == true`),
ask the producer for the per-chunk offsets/lengths via
`DSGetBufferChunkData`, decode each one against the binding cached on
`cam`, and stash the result in `frame.chunks`. Returns `frame`.

If `cam.chunk_bindings` is empty, this is a fast no-op.
"""
function decode_chunks!(frame::GenTL.Frame, cam::Camera)
    cb = cam.chunk_bindings
    cb === nothing && return frame
    isempty(cb) && return frame
    decoded = Dict{Symbol,Any}()

    # Path A — canonical: try DSGetBufferChunkData. Yields offsets/lengths
    # that we slice out of the buffer payload by ChunkID.
    if !isempty(cb.canonical)
        ds = cam.datastream.handle
        chunks = try
            GenTL.ds_get_buffer_chunk_data(cam.api, ds, frame.handle)
        catch
            GenTL.SINGLE_CHUNK_DATA[]
        end
        for c in chunks
            b = _find_binding(cb.canonical, c.ChunkID)
            b === nothing && continue
            try
                decoded[b.name] = _decode_chunk_value(b.node, frame.data,
                    Int(c.ChunkOffset), Int(c.ChunkLength))
            catch e
                decoded[b.name] = e
            end
        end
    end

    # Path B — producer-virtual (mvBlueFOX-style): the chunk feature has
    # no ChunkID but reading it through the nodemap returns the per-frame
    # value because the producer routes the underlying register read to
    # the buffer metadata. We pull each binding's value via get_feature,
    # but the per-node read cache would otherwise hand back the value of
    # the *first* frame we ever saw — clear it so each grab pays the
    # register read.
    for b in cb.virtual
        _invalidate_chain_cache!(b.node)
        try
            decoded[b.name] = get_feature(cam, b.node.name)
        catch e
            decoded[b.name] = e
        end
    end

    isempty(decoded) || (frame.chunks = decoded)
    return frame
end

"""
    img_chunks(decoded_frame) -> Dict{Symbol,Any} or nothing

Convenience accessor: pulls the chunks dict off a `DecodedFrame`'s
underlying buffer if one is attached (only available when the camera
had chunks enabled at capture time).
"""
img_chunks(df::DecodedFrame) = nothing  # DecodedFrame doesn't carry chunks
                                          # — call decode_chunks! on the
                                          # raw Frame instead

"""
    last_chunks(cam) -> Dict{Symbol,Any} or nothing

The chunks dict from the most recent `grab` or stream-yielded frame, or
`nothing` if no chunks have been seen yet.
"""
last_chunks(cam::Camera) = cam.last_chunks

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

@inline function _find_binding(bindings::Vector{ChunkBinding}, id::UInt64)
    for b in bindings
        b.chunk_id == id && return b
    end
    return nothing
end

# Walk the pvalue chain from a chunk-feature node and clear every cache
# slot encountered — the producer-virtual mechanism returns different
# values per frame, but only if we actually re-read from the device.
function _invalidate_chain_cache!(n::GenApi.Node)
    GenApi.cache_clear!(n.meta.cache)
    if hasfield(typeof(n), :pvalue_node)
        target = getfield(n, :pvalue_node)
        target isa GenApi.Node || return
        _invalidate_chain_cache!(target)
    end
    return
end

# Decode a chunk's bytes into a typed value based on the binding node's
# kind. Most chunks are integers (timestamps, frame IDs, counts), some
# are floats (exposure-at-capture, gain-at-capture), and a few are
# strings or raw bytes.
function _decode_chunk_value(node::GenApi.Node, buf::Vector{UInt8},
                              offset::Int, length::Int)
    bytes = view(buf, (offset + 1):(offset + length))
    return _decode_chunk_dispatch(node, bytes, length)
end

function _decode_chunk_dispatch(n::GenApi.IntRegNode, bytes, len)
    return GenApi._decode_int(collect(bytes), n.endianess, n.sign)
end

function _decode_chunk_dispatch(n::GenApi.MaskedIntRegNode, bytes, len)
    raw = GenApi._decode_int(collect(bytes), n.endianess, GenApi.UNSIGNED)
    width = n.msb - n.lsb + 1
    mask = width == 64 ? typemax(UInt64) : (UInt64(1) << width) - UInt64(1)
    field = (UInt64(raw) >> n.lsb) & mask
    if n.sign === GenApi.SIGNED
        sign_bit = UInt64(1) << (width - 1)
        (field & sign_bit) != 0 && (field |= ~mask)
        return reinterpret(Int64, field)
    end
    return Int64(field)
end

function _decode_chunk_dispatch(n::GenApi.FloatRegNode, bytes, len)
    bv = collect(bytes)
    if n.length == 4 || len == 4
        u = UInt32(GenApi._decode_int(bv, n.endianess, GenApi.UNSIGNED) & 0xFFFFFFFF)
        return Float64(reinterpret(Float32, u))
    end
    u = UInt64(GenApi._decode_int(bv, n.endianess, GenApi.UNSIGNED))
    return reinterpret(Float64, u)
end

function _decode_chunk_dispatch(n::GenApi.StringRegNode, bytes, len)
    bv = collect(bytes)
    nul = findfirst(==(0x00), bv)
    end_idx = nul === nothing ? length(bv) : nul - 1
    return String(bv[1:end_idx])
end

# Higher-level value nodes delegate to their backing register for chunk
# decoding — chunk bytes are the register payload by definition.
function _decode_chunk_dispatch(n::GenApi.IntegerNode, bytes, len)
    target = n.pvalue_node
    target === nothing && return collect(bytes)
    return _decode_chunk_dispatch(target, bytes, len)
end

function _decode_chunk_dispatch(n::GenApi.FloatNode, bytes, len)
    target = n.pvalue_node
    target === nothing && return collect(bytes)
    return _decode_chunk_dispatch(target, bytes, len)
end

function _decode_chunk_dispatch(n::GenApi.EnumerationNode, bytes, len)
    target = n.pvalue_node
    target === nothing && return collect(bytes)
    raw = _decode_chunk_dispatch(target, bytes, len)
    raw isa Integer || return raw
    for e in n.entries
        e.value == raw && return e.name
    end
    return raw
end

function _decode_chunk_dispatch(n::GenApi.ConverterNode, bytes, len)
    target = n.pvalue_node
    target === nothing && return collect(bytes)
    raw = _decode_chunk_dispatch(target, bytes, len)
    # We don't run the FormulaFrom here — it would require a port handle
    # for any pVariable indirections, which we don't have for a chunk-only
    # decode path. Return the raw register value with a hint in the type.
    return raw
end

_decode_chunk_dispatch(n::GenApi.IntConverterNode, bytes, len) =
    _decode_chunk_dispatch(GenApi.ConverterNode, bytes, len)   # same fallback

# Default: hand back the raw bytes for anything we don't recognize.
_decode_chunk_dispatch(::GenApi.Node, bytes, len) = collect(bytes)
