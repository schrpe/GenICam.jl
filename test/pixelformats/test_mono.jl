using Test
using GenICam
using GenICam.PixelFormats
using ColorTypes
using FixedPointNumbers

@testset "PixelFormats: Mono8" begin
    bytes = UInt8[0, 64, 128, 255,
                  16, 32, 48, 64]
    f = fakeframe(bytes, 4, 2, 0x01080001)
    df = decode_frame(f)
    @test df.pixel_format === :Mono8
    @test df.cfa === :none
    @test size(df.image) == (2, 4)
    @test eltype(df.image) === Gray{N0f8}
    # row-major source: row 0 = first 4 bytes, row 1 = next 4
    @test reinterpret(UInt8, df.image[1, 1]) == 0
    @test reinterpret(UInt8, df.image[1, 2]) == 64
    @test reinterpret(UInt8, df.image[1, 4]) == 255
    @test reinterpret(UInt8, df.image[2, 1]) == 16
    @test reinterpret(UInt8, df.image[2, 4]) == 64
end

@testset "PixelFormats: Mono16" begin
    # 4 pixels: 0x0000, 0x4000, 0x8000, 0xFFFF — little-endian
    bytes = UInt8[0x00, 0x00, 0x00, 0x40, 0x00, 0x80, 0xFF, 0xFF]
    f = fakeframe(bytes, 4, 1, 0x01100007)
    df = decode_frame(f)
    @test df.pixel_format === :Mono16
    @test eltype(df.image) === Gray{N0f16}
    @test reinterpret(UInt16, df.image[1, 1]) == 0x0000
    @test reinterpret(UInt16, df.image[1, 2]) == 0x4000
    @test reinterpret(UInt16, df.image[1, 3]) == 0x8000
    @test reinterpret(UInt16, df.image[1, 4]) == 0xFFFF
end

@testset "PixelFormats: Mono10 (right-justified, shifted to N0f16)" begin
    # 2 pixels: raw values 0 and 1023 (full-scale 10-bit), little-endian
    bytes = UInt8[0x00, 0x00, 0xFF, 0x03]
    f = fakeframe(bytes, 2, 1, 0x01100003)
    df = decode_frame(f)
    @test df.pixel_format === :Mono10
    @test eltype(df.image) === Gray{N0f16}
    # 0 → 0; 1023 → 1023 << 6 = 65472 (top 10 bits, low 6 zero)
    @test reinterpret(UInt16, df.image[1, 1]) == 0x0000
    @test reinterpret(UInt16, df.image[1, 2]) == UInt16(1023) << 6
end

@testset "PixelFormats: Mono12 padded" begin
    # 1 pixel: raw 4095 (full-scale 12-bit) → shifted left by 4 → 0xFFF0
    bytes = UInt8[0xFF, 0x0F]
    f = fakeframe(bytes, 1, 1, 0x01100005)
    df = decode_frame(f)
    @test reinterpret(UInt16, df.image[1, 1]) == UInt16(0xFFF0)
end

@testset "PixelFormats: Mono10p (4 pix in 5 bytes)" begin
    # Encode 4 pixels with values 0, 1, 1023, 512 LSB-first.
    # pix0 = 0,  pix1 = 1,  pix2 = 1023, pix3 = 512
    # Pack:
    #   b0[7:0]  = pix0[7:0]                       = 0
    #   b1[1:0]  = pix0[9:8]                       = 0
    #   b1[7:2]  = pix1[5:0]                       = 1
    #   b2[3:0]  = pix1[9:6]                       = 0
    #   b2[7:4]  = pix2[3:0]                       = 0xF
    #   b3[5:0]  = pix2[9:4]                       = 0x3F
    #   b3[7:6]  = pix3[1:0]                       = 0
    #   b4[7:0]  = pix3[9:2]                       = 128
    b0 = UInt8(0)
    b1 = UInt8(0x04)            # pix1=1 in bits[7:2]
    b2 = UInt8(0xF0)            # pix2 low nibble in [7:4], pix1 high in [3:0]=0
    b3 = UInt8(0x3F)            # pix2 high 6 bits in [5:0]; pix3 low 2 bits = 0
    b4 = UInt8(128)             # pix3 high 8 bits
    bytes = UInt8[b0, b1, b2, b3, b4]
    f = fakeframe(bytes, 4, 1, 0x010A0046)
    df = decode_frame(f)
    @test df.pixel_format === :Mono10p
    # Values shifted left by 6 to fill N0f16
    @test reinterpret(UInt16, df.image[1, 1]) == UInt16(0)    << 6
    @test reinterpret(UInt16, df.image[1, 2]) == UInt16(1)    << 6
    @test reinterpret(UInt16, df.image[1, 3]) == UInt16(1023) << 6
    @test reinterpret(UInt16, df.image[1, 4]) == UInt16(512)  << 6
end

@testset "PixelFormats: Mono12p (2 pix in 3 bytes)" begin
    # pix0 = 0xABC, pix1 = 0x123  (12-bit values, LSB-first)
    # b0       = pix0[7:0]                  = 0xBC
    # b1[3:0]  = pix0[11:8]                 = 0xA
    # b1[7:4]  = pix1[3:0]                  = 0x3
    # b2       = pix1[11:4]                 = 0x12
    bytes = UInt8[0xBC, 0x3A, 0x12]
    f = fakeframe(bytes, 2, 1, 0x010C0047)
    df = decode_frame(f)
    @test df.pixel_format === :Mono12p
    @test reinterpret(UInt16, df.image[1, 1]) == UInt16(0xABC) << 4
    @test reinterpret(UInt16, df.image[1, 2]) == UInt16(0x123) << 4
end

@testset "PixelFormats: Mono12Packed (legacy GigE)" begin
    # pix0 = 0xABC, pix1 = 0x123  (12-bit values)
    # b0 = pix0[11:4]                 = 0xAB
    # b1 = pix0[3:0] | pix1[3:0] << 4 = 0xC | 0x30 = 0x3C
    # b2 = pix1[11:4]                 = 0x12
    bytes = UInt8[0xAB, 0x3C, 0x12]
    f = fakeframe(bytes, 2, 1, 0x010C0006)
    df = decode_frame(f)
    @test df.pixel_format === :Mono12Packed
    @test reinterpret(UInt16, df.image[1, 1]) == UInt16(0xABC) << 4
    @test reinterpret(UInt16, df.image[1, 2]) == UInt16(0x123) << 4
end

@testset "PixelFormats: Mono geometry (row-major to (h,w))" begin
    # 6 bytes: row0 = 1,2,3 ; row1 = 4,5,6 → image[r,c] should match row-major
    bytes = UInt8[1, 2, 3, 4, 5, 6]
    f = fakeframe(bytes, 3, 2, 0x01080001)
    df = decode_frame(f)
    @test size(df.image) == (2, 3)
    @test reinterpret(UInt8, df.image[1, 1]) == 1
    @test reinterpret(UInt8, df.image[1, 3]) == 3
    @test reinterpret(UInt8, df.image[2, 1]) == 4
    @test reinterpret(UInt8, df.image[2, 3]) == 6
end

# ---------------------------------------------------------------------------
# Cross-row carry regression tests for the unrolled bit-unpack decoders.
# These exercise the running (r, c) counter when a pixel-quartet/pair straddles
# a row boundary — the buggy variant of the cross-row increment shows up as
# either a column wrap-around glitch or an out-of-bounds write.
# ---------------------------------------------------------------------------

# Pack four 10-bit pixels into a 5-byte Mono10p quartet (PFNC §4.2.6 layout).
function _pack_mono10p_quartet(p0::Integer, p1::Integer, p2::Integer, p3::Integer)
    p0 = UInt16(p0); p1 = UInt16(p1); p2 = UInt16(p2); p3 = UInt16(p3)
    b0 = UInt8(p0 & 0xFF)
    b1 = UInt8(((p0 >> 8) & 0x03) | ((p1 & 0x3F) << 2))
    b2 = UInt8(((p1 >> 6) & 0x0F) | ((p2 & 0x0F) << 4))
    b3 = UInt8(((p2 >> 4) & 0x3F) | ((p3 & 0x03) << 6))
    b4 = UInt8((p3 >> 2) & 0xFF)
    return UInt8[b0, b1, b2, b3, b4]
end

@testset "PixelFormats: Mono10p 5x4 (cross-row carry within quartet)" begin
    # Width 5 with 4-pixel quartets means every quartet after the first
    # straddles a row boundary (chunk 2 lands cols 5,1,2,3 — crossing rows).
    # 20 pixels packed as 5 quartets of 5 bytes = 25 bytes total.
    bytes = UInt8[]
    k = UInt16(1)
    for _ in 1:5
        append!(bytes, _pack_mono10p_quartet(k, k+1, k+2, k+3))
        k += 4
    end
    f = fakeframe(bytes, 5, 4, 0x010A0046)
    df = decode_frame(f)
    @test size(df.image) == (4, 5)
    @test df.pixel_format === :Mono10p
    # Pixel value v lands at row-major linear index v, i.e. row=(v-1)÷5+1,
    # col=(v-1)%5+1.  Each value is shifted left by 6 to fill N0f16.
    for v in 1:20
        r = ((v - 1) ÷ 5) + 1
        c = ((v - 1) % 5) + 1
        @test reinterpret(UInt16, df.image[r, c]) == UInt16(v) << 6
    end
end

@testset "PixelFormats: Mono12p 3x3 (odd npix, tail with non-trivial (r,c))" begin
    # 9 pixels = 4 pairs + 1 tail.  With w=3, the tail pixel lands at (3, 3)
    # — exercises the tail branch with the running (r, c) at a non-(1,1)
    # position.  Pair 2 (pixels 3, 4) straddles rows 1 and 2.
    pixels = UInt16[1, 2, 3, 4, 5, 6, 7, 8, 9]
    bytes = UInt8[]
    # Pack 4 full pairs.
    for k in 1:2:8
        p0 = pixels[k]; p1 = pixels[k+1]
        push!(bytes, UInt8(p0 & 0xFF))
        push!(bytes, UInt8(((p0 >> 8) & 0x0F) | ((p1 & 0x0F) << 4)))
        push!(bytes, UInt8((p1 >> 4) & 0xFF))
    end
    # Tail pixel (p9) — needs 2 bytes (the decoder reads bytes[i] and bytes[i+1]).
    p_tail = pixels[9]
    push!(bytes, UInt8(p_tail & 0xFF))
    push!(bytes, UInt8((p_tail >> 8) & 0x0F))
    f = fakeframe(bytes, 3, 3, 0x010C0047)
    df = decode_frame(f)
    @test size(df.image) == (3, 3)
    @test df.pixel_format === :Mono12p
    for v in 1:9
        r = ((v - 1) ÷ 3) + 1
        c = ((v - 1) % 3) + 1
        @test reinterpret(UInt16, df.image[r, c]) == UInt16(v) << 4
    end
end
