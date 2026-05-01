"""
PFNC pixel-format registry.

Each entry maps a `(namespace, code)` tuple to a `PixelFormatSpec` describing
how to decode the buffer. The same numeric code shows up under multiple
namespaces (legacy GEV, modern PFNC 32-bit) — registering both lets the
lookup work no matter which namespace the producer reports.

The decoder field is a `Symbol`. Decoders dispatch on `Val(:symbol)` so the
registry stays a `const Dict` (keys/values fully concrete) without paying a
function-pointer indirection at the call site.
"""

# ---------------------------------------------------------------------------
# PixelFormatSpec
# ---------------------------------------------------------------------------

"""
    PixelFormatSpec

Describes one PFNC pixel format:
  * `name`            — symbolic name (`:Mono8`, `:BayerRG12p`, `:RGB10p32`, ...)
  * `bits_per_pixel`  — declared bit depth (used for buffer-size checks)
  * `family`          — one of `:mono`, `:bayer`, `:rgb`, `:bgr`, `:rgba`,
                        `:bgra`, `:yuv422`, `:yuv411`, `:yuv444`
  * `cfa`             — Bayer pattern (`:GRBG`/`:RGGB`/`:GBRG`/`:BGGR`) or `:none`
  * `decoder`         — `Val`-dispatch tag for the unpacker
"""
struct PixelFormatSpec
    name::Symbol
    bits_per_pixel::Int
    family::Symbol
    cfa::Symbol
    decoder::Symbol
end

# ---------------------------------------------------------------------------
# Format definitions — single source of truth
# ---------------------------------------------------------------------------

# Each tuple: (code, name, bpp, family, cfa, decoder)
const _FORMATS = (
    # ---- Monochrome ----
    (0x01010001, :Mono1p,         1,  :mono,  :none, :decode_mono1p),
    (0x01020001, :Mono2p,         2,  :mono,  :none, :decode_mono2p),
    (0x01040001, :Mono4p,         4,  :mono,  :none, :decode_mono4p),
    (0x01080001, :Mono8,          8,  :mono,  :none, :decode_mono8),
    (0x01100003, :Mono10,         16, :mono,  :none, :decode_mono10),
    (0x010A0046, :Mono10p,        10, :mono,  :none, :decode_mono10p),
    (0x010C0004, :Mono10Packed,   12, :mono,  :none, :decode_mono10packed),
    (0x01100005, :Mono12,         16, :mono,  :none, :decode_mono12),
    (0x010C0047, :Mono12p,        12, :mono,  :none, :decode_mono12p),
    (0x010C0006, :Mono12Packed,   12, :mono,  :none, :decode_mono12packed),
    (0x01100025, :Mono14,         16, :mono,  :none, :decode_mono14),
    (0x01100007, :Mono16,         16, :mono,  :none, :decode_mono16),

    # ---- Bayer 8-bit ----
    (0x01080008, :BayerGR8,       8,  :bayer, :GRBG, :decode_bayer8),
    (0x01080009, :BayerRG8,       8,  :bayer, :RGGB, :decode_bayer8),
    (0x0108000A, :BayerGB8,       8,  :bayer, :GBRG, :decode_bayer8),
    (0x0108000B, :BayerBG8,       8,  :bayer, :BGGR, :decode_bayer8),

    # ---- Bayer 10-bit unpacked (2-byte aligned, 10 meaningful bits) ----
    (0x0110000C, :BayerGR10,      10, :bayer, :GRBG, :decode_bayer10),
    (0x0110000D, :BayerRG10,      10, :bayer, :RGGB, :decode_bayer10),
    (0x0110000E, :BayerGB10,      10, :bayer, :GBRG, :decode_bayer10),
    (0x0110000F, :BayerBG10,      10, :bayer, :BGGR, :decode_bayer10),

    # ---- Bayer 12-bit unpacked (12 meaningful bits in 16-bit container) ----
    (0x01100010, :BayerGR12,      12, :bayer, :GRBG, :decode_bayer12),
    (0x01100011, :BayerRG12,      12, :bayer, :RGGB, :decode_bayer12),
    (0x01100012, :BayerGB12,      12, :bayer, :GBRG, :decode_bayer12),
    (0x01100013, :BayerBG12,      12, :bayer, :BGGR, :decode_bayer12),

    # ---- Bayer 12-bit packed (legacy GigE style) ----
    (0x010C002A, :BayerGR12Packed, 12, :bayer, :GRBG, :decode_bayer12packed),
    (0x010C002B, :BayerRG12Packed, 12, :bayer, :RGGB, :decode_bayer12packed),
    (0x010C002C, :BayerGB12Packed, 12, :bayer, :GBRG, :decode_bayer12packed),
    (0x010C002D, :BayerBG12Packed, 12, :bayer, :BGGR, :decode_bayer12packed),

    # ---- Bayer 10-bit packed (modern PFNC 'p' suffix) ----
    (0x010A0052, :BayerGR10p,     10, :bayer, :GRBG, :decode_bayer10p),
    (0x010A0054, :BayerRG10p,     10, :bayer, :RGGB, :decode_bayer10p),
    (0x010A0056, :BayerGB10p,     10, :bayer, :GBRG, :decode_bayer10p),
    (0x010A0058, :BayerBG10p,     10, :bayer, :BGGR, :decode_bayer10p),

    # ---- Bayer 12-bit packed (modern PFNC 'p' suffix) ----
    (0x010C0053, :BayerGR12p,     12, :bayer, :GRBG, :decode_bayer12p),
    (0x010C0055, :BayerRG12p,     12, :bayer, :RGGB, :decode_bayer12p),
    (0x010C0057, :BayerGB12p,     12, :bayer, :GBRG, :decode_bayer12p),
    (0x010C0059, :BayerBG12p,     12, :bayer, :BGGR, :decode_bayer12p),

    # ---- Bayer 16-bit ----
    (0x0110002E, :BayerGR16,      16, :bayer, :GRBG, :decode_bayer16),
    (0x0110002F, :BayerRG16,      16, :bayer, :RGGB, :decode_bayer16),
    (0x01100030, :BayerGB16,      16, :bayer, :GBRG, :decode_bayer16),
    (0x01100031, :BayerBG16,      16, :bayer, :BGGR, :decode_bayer16),

    # ---- RGB ----
    (0x02180014, :RGB8,           24, :rgb,   :none, :decode_rgb8),
    (0x02180015, :BGR8,           24, :bgr,   :none, :decode_bgr8),
    (0x02300018, :RGB10,          48, :rgb,   :none, :decode_rgb16),
    (0x02300019, :BGR10,          48, :bgr,   :none, :decode_bgr16),
    (0x0230001A, :RGB12,          48, :rgb,   :none, :decode_rgb16),
    (0x0230001B, :BGR12,          48, :bgr,   :none, :decode_bgr16),
    (0x0230005E, :RGB14,          48, :rgb,   :none, :decode_rgb16),
    (0x02300033, :RGB16,          48, :rgb,   :none, :decode_rgb16),
    (0x0230004B, :BGR16,          48, :bgr,   :none, :decode_bgr16),
    (0x0220001D, :RGB10p32,       32, :rgb,   :none, :decode_rgb10p32),
    (0x0220001E, :BGR10p32,       32, :bgr,   :none, :decode_bgr10p32),

    # ---- RGBA / BGRA ----
    (0x02200016, :RGBa8,          32, :rgba,  :none, :decode_rgba8),
    (0x02200017, :BGRa8,          32, :bgra,  :none, :decode_bgra8),

    # ---- YUV ----
    (0x0210001F, :YUV422_8_UYVY,  16, :yuv422, :none, :decode_yuv422_uyvy),
    (0x02100032, :YUV422_8,       16, :yuv422, :none, :decode_yuv422_yuyv),
    (0x020C001E, :YUV411_8_UYYVYY, 12, :yuv411, :none, :decode_yuv411_uyyvyy),
    (0x02180020, :YUV8_UYV,       24, :yuv444, :none, :decode_yuv444_uyv),
)

# ---------------------------------------------------------------------------
# Lookup tables
# ---------------------------------------------------------------------------

const _NS_GEV   = UInt64(Int(PIXELFORMAT_NAMESPACE_GEV))
const _NS_PFNC16 = UInt64(Int(PIXELFORMAT_NAMESPACE_PFNC_16BIT))
const _NS_PFNC32 = UInt64(Int(PIXELFORMAT_NAMESPACE_PFNC_32BIT))
const _NS_UNKNOWN = UInt64(0)

"""
Map `(namespace::UInt64, code::UInt64) -> PixelFormatSpec`.

Producers report the same numeric code under different namespaces depending
on vintage. We register each format under every plausible namespace so the
lookup succeeds regardless.
"""
const PFNC_FORMATS = let
    d = Dict{Tuple{UInt64,UInt64},PixelFormatSpec}()
    for (code, name, bpp, family, cfa, decoder) in _FORMATS
        spec = PixelFormatSpec(name, bpp, family, cfa, decoder)
        c = UInt64(code)
        d[(_NS_GEV, c)]    = spec
        d[(_NS_PFNC32, c)] = spec
        d[(_NS_UNKNOWN, c)] = spec
        # PFNC 16-bit namespace uses a different (shorter) numbering scheme;
        # don't auto-register there.
    end
    d
end

const _FORMATS_BY_NAME = let
    d = Dict{Symbol,PixelFormatSpec}()
    for (code, name, bpp, family, cfa, decoder) in _FORMATS
        d[name] = PixelFormatSpec(name, bpp, family, cfa, decoder)
    end
    d
end

# ---------------------------------------------------------------------------
# Lookup helpers
# ---------------------------------------------------------------------------

"""
    spec_for_code(namespace, code) -> PixelFormatSpec or nothing

Resolve `(BUFFER_INFO_PIXELFORMAT_NAMESPACE, BUFFER_INFO_PIXELFORMAT)` to a
known format. Returns `nothing` if the pair is not in the registry.
"""
@inline function spec_for_code(namespace::Integer, code::Integer)
    return get(PFNC_FORMATS, (UInt64(namespace), UInt64(code)), nothing)
end

"""
    spec_for_name(name::Symbol) -> PixelFormatSpec or nothing

Resolve a PFNC symbolic name (e.g. `:Mono8`, `:BayerRG12p`). Useful as a
fallback when the producer doesn't populate the buffer's pixel-format fields
and the only ground truth is the GenApi `PixelFormat` enumeration string.
"""
@inline function spec_for_name(name::Symbol)
    return get(_FORMATS_BY_NAME, name, nothing)
end
