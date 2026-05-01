"""
Per-format decoders, dispatched on `Val(:decode_*)` symbols stored in
`PixelFormatSpec.decoder`.

Each decoder takes the raw `Frame` plus the spec and returns a `DecodedFrame`
whose `image` field is a typed Julia matrix sized `(height, width)`. Camera
buffers are row-major; Julia matrices are column-major; the standard idiom
to bridge them is `permutedims(reshape(linear, width, height))`, which costs
one allocation but produces the natural `img[row, col]` indexing.

Pixel-format codes pinned by the PFNC standard
(https://www.emva.org/wp-content/uploads/PFNC.h). For packed formats the
layout comments cite the spec section and bit ordering explicitly.
"""

# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

@inline function _wh(frame::Frame)
    w = Int(frame.width)
    h = Int(frame.height)
    (w == 0 || h == 0) && throw(ArgumentError(
        "frame width/height not populated by producer; pass Width/Height " *
        "from the GenApi nodemap or use a producer that fills BUFFER_INFO_*"))
    return (w, h)
end

@inline function _payload_view(frame::Frame, expected::Integer)
    n = Int(frame.size_filled)
    n < expected && throw(ArgumentError(
        "buffer fill ($n bytes) shorter than expected payload ($expected)"))
    return view(frame.data, 1:expected)
end

# Reshape a row-major linear buffer of element type T into a column-major
# Matrix{T} of size (h, w) so that img[r, c] indexes naturally.
@inline function _row_major_to_matrix(linear::AbstractVector, w::Integer, h::Integer)
    return permutedims(reshape(linear, w, h))
end

# ---------------------------------------------------------------------------
# Monochrome — unpacked
# ---------------------------------------------------------------------------

function _decode(::Val{:decode_mono8}, frame::Frame, spec::PixelFormatSpec)
    w, h = _wh(frame)
    bytes = _payload_view(frame, w * h)
    src = reinterpret(Gray{N0f8}, bytes)
    img = _row_major_to_matrix(src, w, h)
    return DecodedFrame(img, spec.name, :none)
end

function _decode(::Val{:decode_mono16}, frame::Frame, spec::PixelFormatSpec)
    w, h = _wh(frame)
    bytes = _payload_view(frame, 2 * w * h)
    src = reinterpret(Gray{N0f16}, bytes)
    img = _row_major_to_matrix(src, w, h)
    return DecodedFrame(img, spec.name, :none)
end

# Mono10 / Mono12 / Mono14 are right-justified in a 16-bit container per PFNC
# (the relevant N bits live in the low N bits of each UInt16). Left-shift by
# (16 - N) so the value spans the full N0f16 range — otherwise a fully-bright
# Mono10 pixel would only register as ~1023/65535 ≈ 1.6% intensity.
function _decode_padded_mono(frame::Frame, spec::PixelFormatSpec, bits::Int)
    w, h = _wh(frame)
    bytes = _payload_view(frame, 2 * w * h)
    raws = reinterpret(UInt16, bytes)
    shift = 16 - bits
    out = Vector{Gray{N0f16}}(undef, w * h)
    @inbounds for i in eachindex(raws)
        out[i] = reinterpret(Gray{N0f16}, UInt16(raws[i]) << shift)
    end
    return DecodedFrame(_row_major_to_matrix(out, w, h), spec.name, :none)
end

_decode(::Val{:decode_mono10}, f::Frame, s::PixelFormatSpec) = _decode_padded_mono(f, s, 10)
_decode(::Val{:decode_mono12}, f::Frame, s::PixelFormatSpec) = _decode_padded_mono(f, s, 12)
_decode(::Val{:decode_mono14}, f::Frame, s::PixelFormatSpec) = _decode_padded_mono(f, s, 14)

# ---------------------------------------------------------------------------
# Monochrome — sub-byte (rare; multiple pixels per byte, MSB-first per PFNC)
# ---------------------------------------------------------------------------

function _decode_subbyte_mono(frame::Frame, spec::PixelFormatSpec, bits::Int)
    w, h = _wh(frame)
    pixels_per_byte = 8 ÷ bits
    expected = cld(w * h, pixels_per_byte)
    bytes = _payload_view(frame, expected)
    out = Vector{Gray{N0f8}}(undef, w * h)
    mask = UInt8((1 << bits) - 1)
    scale = 255 ÷ mask                      # expand to full 0..255 range
    idx = 0
    @inbounds for b in bytes
        for sub in (pixels_per_byte - 1):-1:0
            idx += 1
            idx > w * h && break
            v = (b >> (sub * bits)) & mask
            out[idx] = reinterpret(Gray{N0f8}, UInt8(v * scale))
        end
    end
    return DecodedFrame(_row_major_to_matrix(out, w, h), spec.name, :none)
end

_decode(::Val{:decode_mono1p}, f::Frame, s::PixelFormatSpec) = _decode_subbyte_mono(f, s, 1)
_decode(::Val{:decode_mono2p}, f::Frame, s::PixelFormatSpec) = _decode_subbyte_mono(f, s, 2)
_decode(::Val{:decode_mono4p}, f::Frame, s::PixelFormatSpec) = _decode_subbyte_mono(f, s, 4)

# ---------------------------------------------------------------------------
# Monochrome — packed (PFNC 'p' suffix, modern)
# ---------------------------------------------------------------------------

# Mono10p (PFNC §4.2.6): 4 pixels in 5 bytes, LSB-first stream.
#   pix0 = byte0[7:0]                | (byte1[1:0] << 8)
#   pix1 = byte1[7:2] >> 0           | (byte2[3:0] << 6)
#   pix2 = byte2[7:4] >> 0           | (byte3[5:0] << 4)
#   pix3 = byte3[7:6] >> 0           | (byte4[7:0] << 2)
function _decode(::Val{:decode_mono10p}, frame::Frame, spec::PixelFormatSpec)
    w, h = _wh(frame)
    npix = w * h
    expected = cld(npix * 10, 8)
    bytes = _payload_view(frame, expected)
    out = Vector{Gray{N0f16}}(undef, npix)
    @inbounds begin
        i = 1
        j = 0
        while i + 4 <= length(bytes) + 1 && j + 3 < npix
            b0 = UInt16(bytes[i])
            b1 = UInt16(bytes[i+1])
            b2 = UInt16(bytes[i+2])
            b3 = UInt16(bytes[i+3])
            b4 = UInt16(bytes[i+4])
            p0 = b0 | ((b1 & 0x03) << 8)
            p1 = (b1 >> 2) | ((b2 & 0x0F) << 6)
            p2 = (b2 >> 4) | ((b3 & 0x3F) << 4)
            p3 = (b3 >> 6) | (b4 << 2)
            out[j+1] = reinterpret(Gray{N0f16}, p0 << 6)
            out[j+2] = reinterpret(Gray{N0f16}, p1 << 6)
            out[j+3] = reinterpret(Gray{N0f16}, p2 << 6)
            out[j+4] = reinterpret(Gray{N0f16}, p3 << 6)
            i += 5
            j += 4
        end
        # tail (1-3 leftover pixels) — straight bit-extract
        bitpos = (i - 1) * 8
        while j < npix
            b = bitpos ÷ 8
            o = bitpos & 7
            v = (UInt32(bytes[b+1]) | (UInt32(bytes[b+2]) << 8)) >> o
            out[j+1] = reinterpret(Gray{N0f16}, UInt16(v & 0x03FF) << 6)
            bitpos += 10
            j += 1
        end
    end
    return DecodedFrame(_row_major_to_matrix(out, w, h), spec.name, :none)
end

# Mono12p (PFNC §4.2.7): 2 pixels in 3 bytes, LSB-first.
#   pix0 = byte0       | ((byte1 & 0x0F) << 8)
#   pix1 = (byte1 >> 4) | (byte2 << 4)
function _decode(::Val{:decode_mono12p}, frame::Frame, spec::PixelFormatSpec)
    w, h = _wh(frame)
    npix = w * h
    expected = cld(npix * 12, 8)
    bytes = _payload_view(frame, expected)
    out = Vector{Gray{N0f16}}(undef, npix)
    @inbounds begin
        i = 1
        j = 0
        while j + 2 <= npix
            b0 = UInt16(bytes[i])
            b1 = UInt16(bytes[i+1])
            b2 = UInt16(bytes[i+2])
            p0 = b0 | ((b1 & 0x0F) << 8)
            p1 = (b1 >> 4) | (b2 << 4)
            out[j+1] = reinterpret(Gray{N0f16}, p0 << 4)
            out[j+2] = reinterpret(Gray{N0f16}, p1 << 4)
            i += 3
            j += 2
        end
        # tail (1 pixel) if odd npix
        if j < npix
            b0 = UInt16(bytes[i])
            b1 = UInt16(bytes[i+1])
            out[j+1] = reinterpret(Gray{N0f16}, (b0 | ((b1 & 0x0F) << 8)) << 4)
        end
    end
    return DecodedFrame(_row_major_to_matrix(out, w, h), spec.name, :none)
end

# Mono10Packed (legacy GigE Vision): 2 pixels in 3 bytes; byte1 holds the
# low 2 bits of pix0 (low nibble) and the low 2 bits of pix1 (high nibble);
# byte0 = pix0[9:2], byte2 = pix1[9:2].
function _decode(::Val{:decode_mono10packed}, frame::Frame, spec::PixelFormatSpec)
    w, h = _wh(frame)
    npix = w * h
    expected = cld(npix * 12, 8)            # 12 bytes per 8 pixels = 1.5 bytes/pixel
    bytes = _payload_view(frame, expected)
    out = Vector{Gray{N0f16}}(undef, npix)
    @inbounds begin
        i = 1
        j = 0
        while j + 2 <= npix
            b0 = UInt16(bytes[i])
            b1 = UInt16(bytes[i+1])
            b2 = UInt16(bytes[i+2])
            p0 = (b0 << 2) | (b1 & 0x03)
            p1 = (b2 << 2) | ((b1 >> 4) & 0x03)
            out[j+1] = reinterpret(Gray{N0f16}, p0 << 6)
            out[j+2] = reinterpret(Gray{N0f16}, p1 << 6)
            i += 3
            j += 2
        end
        if j < npix
            out[j+1] = reinterpret(Gray{N0f16},
                ((UInt16(bytes[i]) << 2) | (UInt16(bytes[i+1]) & 0x03)) << 6)
        end
    end
    return DecodedFrame(_row_major_to_matrix(out, w, h), spec.name, :none)
end

# Mono12Packed (legacy GigE Vision): 2 pixels in 3 bytes.
#   byte0 = pix0[11:4]
#   byte1 = pix0[3:0] (low nibble) | pix1[3:0] (high nibble)
#   byte2 = pix1[11:4]
function _decode(::Val{:decode_mono12packed}, frame::Frame, spec::PixelFormatSpec)
    w, h = _wh(frame)
    npix = w * h
    expected = cld(npix * 12, 8)
    bytes = _payload_view(frame, expected)
    out = Vector{Gray{N0f16}}(undef, npix)
    @inbounds begin
        i = 1
        j = 0
        while j + 2 <= npix
            b0 = UInt16(bytes[i])
            b1 = UInt16(bytes[i+1])
            b2 = UInt16(bytes[i+2])
            p0 = (b0 << 4) | (b1 & 0x0F)
            p1 = (b2 << 4) | ((b1 >> 4) & 0x0F)
            out[j+1] = reinterpret(Gray{N0f16}, p0 << 4)
            out[j+2] = reinterpret(Gray{N0f16}, p1 << 4)
            i += 3
            j += 2
        end
        if j < npix
            out[j+1] = reinterpret(Gray{N0f16},
                ((UInt16(bytes[i]) << 4) | (UInt16(bytes[i+1]) & 0x0F)) << 4)
        end
    end
    return DecodedFrame(_row_major_to_matrix(out, w, h), spec.name, :none)
end

# ---------------------------------------------------------------------------
# Bayer — same payload layout as Mono of the same depth, only the CFA tag differs
# ---------------------------------------------------------------------------

function _decode(::Val{:decode_bayer8}, frame::Frame, spec::PixelFormatSpec)
    w, h = _wh(frame)
    bytes = _payload_view(frame, w * h)
    src = reinterpret(Gray{N0f8}, bytes)
    img = _row_major_to_matrix(src, w, h)
    return DecodedFrame(img, spec.name, spec.cfa)
end

function _decode_padded_bayer(frame::Frame, spec::PixelFormatSpec, bits::Int)
    # Bayer10/12 are right-justified in a 16-bit container; left-shift the
    # meaningful bits to span the full N0f16 range. Bayer16 is already
    # full-range (shift = 0).
    w, h = _wh(frame)
    bytes = _payload_view(frame, 2 * w * h)
    raws = reinterpret(UInt16, bytes)
    shift = 16 - bits
    out = Vector{Gray{N0f16}}(undef, w * h)
    @inbounds for i in eachindex(raws)
        out[i] = reinterpret(Gray{N0f16}, UInt16(raws[i]) << shift)
    end
    return DecodedFrame(_row_major_to_matrix(out, w, h), spec.name, spec.cfa)
end

_decode(::Val{:decode_bayer10}, f::Frame, s::PixelFormatSpec) = _decode_padded_bayer(f, s, 10)
_decode(::Val{:decode_bayer12}, f::Frame, s::PixelFormatSpec) = _decode_padded_bayer(f, s, 12)
_decode(::Val{:decode_bayer16}, f::Frame, s::PixelFormatSpec) = _decode_padded_bayer(f, s, 16)

function _decode(::Val{:decode_bayer10p}, frame::Frame, spec::PixelFormatSpec)
    inner = _decode(Val(:decode_mono10p), frame, spec)
    return DecodedFrame(inner.image, spec.name, spec.cfa)
end

function _decode(::Val{:decode_bayer12p}, frame::Frame, spec::PixelFormatSpec)
    inner = _decode(Val(:decode_mono12p), frame, spec)
    return DecodedFrame(inner.image, spec.name, spec.cfa)
end

function _decode(::Val{:decode_bayer12packed}, frame::Frame, spec::PixelFormatSpec)
    inner = _decode(Val(:decode_mono12packed), frame, spec)
    return DecodedFrame(inner.image, spec.name, spec.cfa)
end

# ---------------------------------------------------------------------------
# RGB / BGR — interleaved 8-bit per channel
# ---------------------------------------------------------------------------

function _decode(::Val{:decode_rgb8}, frame::Frame, spec::PixelFormatSpec)
    w, h = _wh(frame)
    bytes = _payload_view(frame, 3 * w * h)
    src = reinterpret(RGB{N0f8}, bytes)
    img = _row_major_to_matrix(src, w, h)
    return DecodedFrame(img, spec.name, :none)
end

function _decode(::Val{:decode_bgr8}, frame::Frame, spec::PixelFormatSpec)
    w, h = _wh(frame)
    bytes = _payload_view(frame, 3 * w * h)
    src = reinterpret(BGR{N0f8}, bytes)
    img = _row_major_to_matrix(src, w, h)
    return DecodedFrame(img, spec.name, :none)
end

function _decode(::Val{:decode_rgba8}, frame::Frame, spec::PixelFormatSpec)
    w, h = _wh(frame)
    bytes = _payload_view(frame, 4 * w * h)
    src = reinterpret(RGBA{N0f8}, bytes)
    img = _row_major_to_matrix(src, w, h)
    return DecodedFrame(img, spec.name, :none)
end

function _decode(::Val{:decode_bgra8}, frame::Frame, spec::PixelFormatSpec)
    w, h = _wh(frame)
    bytes = _payload_view(frame, 4 * w * h)
    src = reinterpret(BGRA{N0f8}, bytes)
    img = _row_major_to_matrix(src, w, h)
    return DecodedFrame(img, spec.name, :none)
end

# ---------------------------------------------------------------------------
# RGB / BGR — interleaved 16-bit per channel (covers RGB10/12/14/16 padded)
# ---------------------------------------------------------------------------

function _decode_rgb16_generic(frame::Frame, spec::PixelFormatSpec, ::Type{C}) where {C}
    w, h = _wh(frame)
    npix = w * h
    bytes = _payload_view(frame, 6 * npix)
    raws = reinterpret(UInt16, bytes)        # 3 channels per pixel = 3*npix elements
    bpc = spec.bits_per_pixel ÷ 3            # bits per channel (24 for RGB8 not handled here)
    shift = 16 - bpc
    out = Vector{C}(undef, npix)
    @inbounds for i in 1:npix
        c1 = UInt16(raws[3i-2]) << shift
        c2 = UInt16(raws[3i-1]) << shift
        c3 = UInt16(raws[3i  ]) << shift
        out[i] = if C === RGB{N0f16}
            RGB(reinterpret(N0f16, c1), reinterpret(N0f16, c2), reinterpret(N0f16, c3))
        else  # BGR{N0f16}
            BGR(reinterpret(N0f16, c1), reinterpret(N0f16, c2), reinterpret(N0f16, c3))
        end
    end
    return DecodedFrame(_row_major_to_matrix(out, w, h), spec.name, :none)
end

_decode(::Val{:decode_rgb16}, f::Frame, s::PixelFormatSpec) =
    _decode_rgb16_generic(f, s, RGB{N0f16})

_decode(::Val{:decode_bgr16}, f::Frame, s::PixelFormatSpec) =
    _decode_rgb16_generic(f, s, BGR{N0f16})

# ---------------------------------------------------------------------------
# RGB10p32 / BGR10p32 — three 10-bit channels packed into a 32-bit word
# (PFNC §4.4.5). Bits 0-9: ch0, 10-19: ch1, 20-29: ch2, 30-31: padding.
# Channel order for RGB10p32: R, G, B.   For BGR10p32: B, G, R.
# ---------------------------------------------------------------------------

function _decode_packed10p32(frame::Frame, spec::PixelFormatSpec, ::Type{C}) where {C}
    w, h = _wh(frame)
    npix = w * h
    bytes = _payload_view(frame, 4 * npix)
    words = reinterpret(UInt32, bytes)
    out = Vector{C}(undef, npix)
    @inbounds for i in 1:npix
        word = htol(words[i])
        c1 = UInt16(word & 0x3FF) << 6
        c2 = UInt16((word >> 10) & 0x3FF) << 6
        c3 = UInt16((word >> 20) & 0x3FF) << 6
        out[i] = if C === RGB{N0f16}
            RGB(reinterpret(N0f16, c1), reinterpret(N0f16, c2), reinterpret(N0f16, c3))
        else
            BGR(reinterpret(N0f16, c1), reinterpret(N0f16, c2), reinterpret(N0f16, c3))
        end
    end
    return DecodedFrame(_row_major_to_matrix(out, w, h), spec.name, :none)
end

_decode(::Val{:decode_rgb10p32}, f::Frame, s::PixelFormatSpec) =
    _decode_packed10p32(f, s, RGB{N0f16})

_decode(::Val{:decode_bgr10p32}, f::Frame, s::PixelFormatSpec) =
    _decode_packed10p32(f, s, BGR{N0f16})

# ---------------------------------------------------------------------------
# YUV — converted to RGB{N0f8} via ITU-R BT.601 limited range
# ---------------------------------------------------------------------------

@inline function _yuv_to_rgb(y::UInt8, cb::UInt8, cr::UInt8)
    yi = Int(y)
    cbi = Int(cb) - 128
    cri = Int(cr) - 128
    r = clamp(yi + ((1436 * cri) >> 10), 0, 255)
    g = clamp(yi - ((352 * cbi + 731 * cri) >> 10), 0, 255)
    b = clamp(yi + ((1814 * cbi) >> 10), 0, 255)
    return RGB(reinterpret(N0f8, UInt8(r)),
               reinterpret(N0f8, UInt8(g)),
               reinterpret(N0f8, UInt8(b)))
end

# YUV422_8_UYVY: byte order [U, Y0, V, Y1]; 4 bytes encode 2 pixels.
function _decode(::Val{:decode_yuv422_uyvy}, frame::Frame, spec::PixelFormatSpec)
    w, h = _wh(frame)
    npix = w * h
    bytes = _payload_view(frame, 2 * npix)
    out = Vector{RGB{N0f8}}(undef, npix)
    @inbounds for i in 1:2:npix
        idx = (i - 1) * 2 + 1
        u  = bytes[idx]
        y0 = bytes[idx+1]
        v  = bytes[idx+2]
        y1 = bytes[idx+3]
        out[i]   = _yuv_to_rgb(y0, u, v)
        out[i+1] = _yuv_to_rgb(y1, u, v)
    end
    return DecodedFrame(_row_major_to_matrix(out, w, h), spec.name, :none)
end

# YUV422_8: byte order [Y0, U, Y1, V].
function _decode(::Val{:decode_yuv422_yuyv}, frame::Frame, spec::PixelFormatSpec)
    w, h = _wh(frame)
    npix = w * h
    bytes = _payload_view(frame, 2 * npix)
    out = Vector{RGB{N0f8}}(undef, npix)
    @inbounds for i in 1:2:npix
        idx = (i - 1) * 2 + 1
        y0 = bytes[idx]
        u  = bytes[idx+1]
        y1 = bytes[idx+2]
        v  = bytes[idx+3]
        out[i]   = _yuv_to_rgb(y0, u, v)
        out[i+1] = _yuv_to_rgb(y1, u, v)
    end
    return DecodedFrame(_row_major_to_matrix(out, w, h), spec.name, :none)
end

# YUV411_8_UYYVYY: 6 bytes encode 4 pixels. Byte order [U, Y0, Y1, V, Y2, Y3].
function _decode(::Val{:decode_yuv411_uyyvyy}, frame::Frame, spec::PixelFormatSpec)
    w, h = _wh(frame)
    npix = w * h
    bytes = _payload_view(frame, 6 * (npix ÷ 4))
    out = Vector{RGB{N0f8}}(undef, npix)
    @inbounds for i in 1:4:npix
        idx = ((i - 1) ÷ 4) * 6 + 1
        u  = bytes[idx]
        y0 = bytes[idx+1]
        y1 = bytes[idx+2]
        v  = bytes[idx+3]
        y2 = bytes[idx+4]
        y3 = bytes[idx+5]
        out[i]   = _yuv_to_rgb(y0, u, v)
        out[i+1] = _yuv_to_rgb(y1, u, v)
        out[i+2] = _yuv_to_rgb(y2, u, v)
        out[i+3] = _yuv_to_rgb(y3, u, v)
    end
    return DecodedFrame(_row_major_to_matrix(out, w, h), spec.name, :none)
end

# YUV8_UYV: 3 bytes per pixel, no chroma subsampling.
function _decode(::Val{:decode_yuv444_uyv}, frame::Frame, spec::PixelFormatSpec)
    w, h = _wh(frame)
    npix = w * h
    bytes = _payload_view(frame, 3 * npix)
    out = Vector{RGB{N0f8}}(undef, npix)
    @inbounds for i in 1:npix
        idx = (i - 1) * 3 + 1
        u = bytes[idx]
        y = bytes[idx+1]
        v = bytes[idx+2]
        out[i] = _yuv_to_rgb(y, u, v)
    end
    return DecodedFrame(_row_major_to_matrix(out, w, h), spec.name, :none)
end

# ---------------------------------------------------------------------------
# Fallback for any (registered but not yet implemented) decoder symbol
# ---------------------------------------------------------------------------

function _decode(::Val{T}, ::Frame, spec::PixelFormatSpec) where {T}
    throw(ArgumentError(
        "no decoder method for :$T (format $(spec.name)) — please report"))
end
