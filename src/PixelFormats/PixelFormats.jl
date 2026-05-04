"""
    GenICam.PixelFormats

Decoders for the EMVA Pixel Format Naming Convention (PFNC) values delivered
by a GenTL producer in `BUFFER_INFO_PIXELFORMAT` / `BUFFER_INFO_PIXELFORMAT_NAMESPACE`.

Each decoder turns the raw byte buffer the producer wrote into a typed Julia
array, using the standard JuliaImages element types from `ColorTypes` and
`FixedPointNumbers`:

  * Mono8 / Mono16            -> `Matrix{Gray{N0f8}}` / `Matrix{Gray{N0f16}}`
  * Mono10 / Mono12 / Mono14  -> `Matrix{Gray{N0f16}}` (left-shifted to 16-bit)
  * Mono*p / Mono*Packed      -> `Matrix{Gray{N0f16}}` after bit-unpacking
  * RGB8 / BGR8               -> `Matrix{RGB{N0f8}}` / `Matrix{BGR{N0f8}}`
  * RGB10/12/14/16            -> `Matrix{RGB{N0f16}}`
  * RGB10p32 / BGR10p32       -> `Matrix{RGB{N0f16}}` / `Matrix{BGR{N0f16}}`
  * RGBa8 / BGRa8             -> `Matrix{RGBA{N0f8}}` / `Matrix{BGRA{N0f8}}`
  * BayerXX8 / BayerXX16      -> `Matrix{Gray{N0fX}}` + CFA tag (no demosaicing)
  * YUV422_8 / YUV411_8 / ... -> `Matrix{RGB{N0f8}}` after color conversion

Type-stability: callers of `decode_frame` see a `DecodedFrame{A}` where `A`
is `AbstractMatrix` at the boundary. The standard Julia function-barrier
pattern (passing the `image` field to a worker that specialises on its
concrete type) recovers full performance after one runtime dispatch per
frame — fine even at 100+ fps.
"""
module PixelFormats

using ColorTypes
using FixedPointNumbers
using ..GenTL: Frame, BUFFER_INFO_PIXELFORMAT_NAMESPACE,
    PIXELFORMAT_NAMESPACE_GEV, PIXELFORMAT_NAMESPACE_PFNC_16BIT,
    PIXELFORMAT_NAMESPACE_PFNC_32BIT

include("formats.jl")
include("decoders.jl")

# ---------------------------------------------------------------------------
# DecodedFrame — the public output of pixel-format decoding
# ---------------------------------------------------------------------------

"""
    DecodedFrame{A<:AbstractArray}

The result of `decode_frame(frame, cam)`:

  * `image`         — the typed Julia array (`Matrix{Gray{N0f8}}`,
                      `Matrix{RGB{N0f16}}`, ...). Owns its own memory; safe to
                      keep after the underlying GenTL buffer is re-queued.
  * `pixel_format`  — the PFNC symbol (e.g. `:Mono8`, `:BayerRG8`, `:RGB10p32`).
  * `cfa`           — `:none` for non-Bayer, otherwise one of `:GRBG`, `:RGGB`,
                      `:GBRG`, `:BGGR`. Use this with a demosaicing package
                      (e.g. `Images.jl`) to render Bayer images.
"""
struct DecodedFrame{A<:AbstractArray}
    image::A
    pixel_format::Symbol
    cfa::Symbol
end

Base.size(f::DecodedFrame) = size(f.image)
Base.size(f::DecodedFrame, d::Integer) = size(f.image, d)
Base.eltype(::Type{DecodedFrame{A}}) where {A} = eltype(A)
Base.length(f::DecodedFrame) = length(f.image)

function Base.show(io::IO, f::DecodedFrame)
    print(io, "DecodedFrame{", eltype(f.image), "}(", f.pixel_format)
    f.cfa === :none || print(io, ", cfa=", f.cfa)
    print(io, ", ", size(f.image, 1), "x", size(f.image, 2), ")")
end

# ---------------------------------------------------------------------------
# decode_frame — entry point
# ---------------------------------------------------------------------------

"""
    decode_frame(frame::Frame; pixel_format_hint=nothing) -> DecodedFrame

Look up `frame.pixel_format` (and `frame.pixel_format_namespace`) in the
PFNC registry, then dispatch to the matching decoder. If the producer didn't
populate the namespace field, pass `pixel_format_hint = :Mono8` (or similar)
to force a specific decoder; this is what `Camera.grab` does when the GenApi
`PixelFormat` enumeration name is the only ground truth.

Throws `UnsupportedPixelFormat` when the (namespace, code) pair is not in
the registry. To opt out of decoding entirely, use `grab_raw` from `Camera`.
"""
function decode_frame(frame::Frame; pixel_format_hint::Union{Symbol,Nothing} = nothing)
    spec = if pixel_format_hint !== nothing
        spec_for_name(pixel_format_hint)
    else
        spec_for_code(frame.pixel_format_namespace, frame.pixel_format)
    end
    spec === nothing && throw(UnsupportedPixelFormat(
        frame.pixel_format, frame.pixel_format_namespace, pixel_format_hint))
    return _decode(Val(spec.decoder), frame, spec)
end

"""
    decode_frame!(pool::BufferPool, frame::Frame; pixel_format_hint=nothing) -> DecodedFrame

Same as [`decode_frame`](@ref) but routes through a [`BufferPool`](@ref)
so the decoder can write into a pre-allocated matrix instead of allocating
a fresh one per frame. Used by [`start_stream`](@ref GenICam.start_stream) when its
`buffer_pool` keyword is supplied.

Falls back to allocating decode for any format that doesn't have a
pool-aware variant (currently the YUV / packed / 16-bit-RGB families) —
correctness is preserved, the pool just doesn't help for those.
"""
function decode_frame!(pool, frame::Frame;
                        pixel_format_hint::Union{Symbol,Nothing} = nothing)
    spec = if pixel_format_hint !== nothing
        spec_for_name(pixel_format_hint)
    else
        spec_for_code(frame.pixel_format_namespace, frame.pixel_format)
    end
    spec === nothing && throw(UnsupportedPixelFormat(
        frame.pixel_format, frame.pixel_format_namespace, pixel_format_hint))
    return _decode!(pool, Val(spec.decoder), frame, spec)
end

"""
    UnsupportedPixelFormat <: Exception

Raised by `decode_frame` when the buffer's pixel format isn't in the PFNC
registry (or when an explicit hint doesn't match any known format).
"""
struct UnsupportedPixelFormat <: Exception
    code::UInt64
    namespace::UInt64
    hint::Union{Symbol,Nothing}
end

function Base.showerror(io::IO, e::UnsupportedPixelFormat)
    print(io, "UnsupportedPixelFormat: ")
    if e.hint !== nothing
        print(io, "no entry for hint :", e.hint)
    else
        print(io, "no entry for (namespace=", Int(e.namespace),
            ", code=0x", string(e.code; base = 16), ")")
    end
end

export DecodedFrame, decode_frame, decode_frame!,
    BufferPool, UnsupportedPixelFormat,
    PixelFormatSpec, spec_for_code, spec_for_name,
    PFNC_FORMATS

end # module
