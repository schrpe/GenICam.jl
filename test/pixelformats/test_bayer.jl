using Test
using GenICam
using GenICam.PixelFormats
using ColorTypes
using FixedPointNumbers

@testset "PixelFormats: Bayer 8-bit (CFA tag carries the pattern)" begin
    bytes = UInt8[1, 2, 3, 4]
    for (code, name, cfa) in (
        (0x01080008, :BayerGR8, :GRBG),
        (0x01080009, :BayerRG8, :RGGB),
        (0x0108000A, :BayerGB8, :GBRG),
        (0x0108000B, :BayerBG8, :BGGR),
    )
        f = fakeframe(bytes, 2, 2, UInt64(code))
        df = decode_frame(f)
        @test df.pixel_format === name
        @test df.cfa === cfa
        @test eltype(df.image) === Gray{N0f8}
        @test size(df.image) == (2, 2)
        # Same byte layout as Mono8 — first row 1,2; second row 3,4
        @test reinterpret(UInt8, df.image[1, 1]) == 1
        @test reinterpret(UInt8, df.image[2, 2]) == 4
    end
end

@testset "PixelFormats: BayerRG12 padded -> N0f16" begin
    # Two pixels: 0x0FFF (full-scale 12-bit) and 0x0001 (lowest), little-endian
    bytes = UInt8[0xFF, 0x0F, 0x01, 0x00]
    f = fakeframe(bytes, 2, 1, 0x01100011)
    df = decode_frame(f)
    @test df.pixel_format === :BayerRG12
    @test df.cfa === :RGGB
    @test eltype(df.image) === Gray{N0f16}
    @test reinterpret(UInt16, df.image[1, 1]) == UInt16(0x0FFF) << 4
    @test reinterpret(UInt16, df.image[1, 2]) == UInt16(0x0001) << 4
end

@testset "PixelFormats: BayerRG16" begin
    bytes = UInt8[0x00, 0x00, 0xFF, 0xFF]
    f = fakeframe(bytes, 2, 1, 0x0110002F)
    df = decode_frame(f)
    @test df.pixel_format === :BayerRG16
    @test df.cfa === :RGGB
    @test reinterpret(UInt16, df.image[1, 1]) == 0x0000
    @test reinterpret(UInt16, df.image[1, 2]) == 0xFFFF
end
