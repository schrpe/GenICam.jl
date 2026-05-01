```@meta
CurrentModule = GenICam
```

# Pixel formats

Cameras deliver images as raw byte buffers; the *pixel format* tells
`GenICam.jl` how to decode those bytes into a typed Julia matrix. The
producer reports the format via `BUFFER_INFO_PIXELFORMAT` and the
namespace via `BUFFER_INFO_PIXELFORMAT_NAMESPACE`; together they look
up an entry in the package's PFNC registry.

## Return type rules

Each decoder produces a typed `Matrix` of `(height, width)` shape, with
element type chosen from the JuliaImages standard:

  * **Mono 8-bit**          → `Matrix{Gray{N0f8}}`
  * **Mono 10/12/14/16**    → `Matrix{Gray{N0f16}}` (left-shifted to fill the range)
  * **RGB / BGR 8-bit**     → `Matrix{RGB{N0f8}}` / `Matrix{BGR{N0f8}}`
  * **RGB / BGR 10/12/14/16** → `Matrix{RGB{N0f16}}` / `Matrix{BGR{N0f16}}`
  * **RGBa / BGRa 8-bit**   → `Matrix{RGBA{N0f8}}` / `Matrix{BGRA{N0f8}}`
  * **Bayer (any depth)**   → `Matrix{Gray{N0fX}}` + `cfa` symbol
  * **YUV (4:2:2 / 4:1:1 / 4:4:4)** → `Matrix{RGB{N0f8}}` (BT.601 conversion)

Why `N0fN` (FixedPointNumbers.jl) and not raw `UIntN`? Because
JuliaImages' pipeline operates on intensities in `[0, 1]`, which means
ImageFiltering / ImageTransformations / Images all "just work" on the
result. To get raw bytes back: `reinterpret(UInt8, frame.image)`.

## DecodedFrame

`grab` returns a `DecodedFrame`; the `image` field is the typed matrix.
`pixel_format` records which PFNC entry was used (e.g. `:Mono8`,
`:BayerRG10p`, `:RGB10p32`). For Bayer formats `cfa` is one of `:GRBG`,
`:RGGB`, `:GBRG`, `:BGGR`; for everything else it's `:none`.

To get raw producer bytes without any decoding, use [`grab_raw`](@ref).

## Supported formats

| Family | Code | bpp | Notes |
|---|---|---:|---|
| **Mono** | `Mono1p`, `Mono2p`, `Mono4p` | 1 / 2 / 4 | sub-byte packed |
| | `Mono8` | 8 | direct |
| | `Mono10`, `Mono12`, `Mono14` | 16 | right-justified 10/12/14 in 16-bit container |
| | `Mono10p`, `Mono12p` | 10 / 12 | tightly packed (modern PFNC) |
| | `Mono10Packed`, `Mono12Packed` | 12 | legacy GigE Vision packing (2 pix/3 bytes) |
| | `Mono16` | 16 | direct |
| **Bayer 8** | `BayerGR8`, `BayerRG8`, `BayerGB8`, `BayerBG8` | 8 | CFA tag in `frame.cfa` |
| **Bayer 10/12** | `BayerGR10`, ... `BayerBG12` | 16 | padded |
| **Bayer 10p/12p** | `BayerGR10p`, ... `BayerBG12p` | 10 / 12 | packed |
| **Bayer 12Packed** | `BayerGR12Packed`, ... | 12 | legacy GigE |
| **Bayer 16** | `BayerGR16`, ... `BayerBG16` | 16 | direct |
| **RGB** | `RGB8`, `BGR8` | 24 | interleaved |
| | `RGB10`, `BGR10`, `RGB12`, `BGR12`, `RGB14`, `RGB16`, `BGR16` | 48 | padded interleaved |
| | `RGB10p32`, `BGR10p32` | 32 | three 10-bit channels packed in 32 bits |
| | `RGBa8`, `BGRa8` | 32 | with alpha |
| **YUV 4:2:2** | `YUV422_8_UYVY`, `YUV422_8` (YUYV) | 16 | converted to `RGB{N0f8}` |
| **YUV 4:1:1** | `YUV411_8_UYYVYY` | 12 | converted to `RGB{N0f8}` |
| **YUV 4:4:4** | `YUV8_UYV` | 24 | converted to `RGB{N0f8}` |

The codes are defined by the EMVA's
[PFNC.h](https://www.emva.org/wp-content/uploads/PFNC.h). Each format
is registered under multiple namespaces (legacy GEV, PFNC 32-bit, plus
a "namespace 0" fallback) so the lookup succeeds whether or not the
producer populates the namespace field.

### Decoding a PFNC code

Each 32-bit PFNC code packs structural information across three byte
ranges:

```
bits 31..24   — Pixel layout marker
                  0x01 = single-component (mono / Bayer)
                  0x02 = multi-component  (RGB, BGR, RGBa, ...)
                  0x03 = multi-part       (3D / depth maps)

bits 23..16   — Effective bits-per-pixel
                  0x08 / 0x10 / 0x0A / 0x0C / 0x18 / 0x20 / 0x30 / ...

bits 15..0    — Format ID (vendor-assigned within the layout/bpp class)
```

Examples:

  * `0x01080001` = Mono8         (single-component, 8 bpp, ID 1)
  * `0x01080009` = BayerRG8      (single-component, 8 bpp, ID 9)
  * `0x01100007` = Mono16        (single-component, 16 bpp, ID 7)
  * `0x02180014` = RGB8          (multi-component, 24 bpp, ID 0x14)
  * `0x010C0006` = Mono12Packed  (single-component, 12 bpp, ID 6)
  * `0x0220001D` = RGB10p32      (multi-component, 32 bpp, ID 0x1D)

The pixel-format namespace IDs the producer reports in
`BUFFER_INFO_PIXELFORMAT_NAMESPACE`:

| Namespace | Meaning |
|---:|---|
| `0` | Unknown / unspecified — `GenICam.jl` falls back to the GenApi `PixelFormat` enum string |
| `1` | Legacy GEV (GigE Vision) |
| `2` | IIDC (FireWire) |
| `3` | PFNC 16-bit (older 16-bit-code variant) |
| `4` | PFNC 32-bit (current standard, what most modern cameras report) |

## Bayer policy: no demosaicing

Bayer-pattern images are returned *raw* — the package does not
interpolate the missing color channels. Instead `frame.cfa` is set to
the pattern (`:RGGB`, `:GRBG`, etc.) and the user picks a demosaicing
package:

```julia
using ImageCore, Images, GenICam

frame = grab(cam)            # PixelFormat = "BayerRG10"
img = frame.image            # Matrix{Gray{N0f16}}
@assert frame.cfa === :RGGB

# pick your favourite debayer:
rgb = demosaic(img, frame.cfa)   # via your own package
```

This keeps `GenICam.jl` focused on standard-compliant decoding; the
ecosystem already has solid demosaicing.

## Type stability

`grab(cam)` returns `DecodedFrame{Matrix{T}}` where `T` depends on the
camera's current `PixelFormat`. That makes the return type
*non-inferable* across all formats — Julia sees a `Union` at the
`grab` call boundary. The standard fix is the *function-barrier*
pattern: pass the result to a worker that specialises on the concrete
`Matrix{T}`:

```julia
function process(cam)
    frame = grab(cam)            # union return at this single call
    _process_typed(frame.image)  # specialised per concrete eltype
end

# The compiler generates one specialisation per Matrix{T} that ever
# reaches this function — fully type-stable inside.
function _process_typed(img::AbstractMatrix)
    histogram = zeros(Int, 256)
    @inbounds for px in img
        histogram[Int(reinterpret(UInt8, px)) + 1] += 1
    end
    return histogram
end
```

In a tight live-preview loop this is the recommended pattern. For
one-shot snapshots the boundary's cost is negligible.

## Looking up format metadata

The PFNC registry is exported from `GenICam.PixelFormats`:

```julia
using GenICam.PixelFormats

spec_for_name(:Mono8)
# PixelFormatSpec(:Mono8, 8, :mono, :none, :decode_mono8)

spec_for_name(:BayerRG12p)
# PixelFormatSpec(:BayerRG12p, 12, :bayer, :RGGB, :decode_bayer12p)

spec_for_code(UInt64(0), UInt64(0x01080001))    # by namespace + code
# PixelFormatSpec(:Mono8, 8, :mono, :none, :decode_mono8)
```

See [API reference](api.md) for the full signatures of `PixelFormatSpec`,
`spec_for_name`, `spec_for_code`, `UnsupportedPixelFormat`, and
`DecodedFrame`.
