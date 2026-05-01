using Test
using GenICam
using GenICam.PixelFormats
using ColorTypes
using FixedPointNumbers

@testset "PixelFormats: RGB8" begin
    # 2x1 image: pixel 0 = (10, 20, 30), pixel 1 = (200, 100, 50)
    bytes = UInt8[10, 20, 30, 200, 100, 50]
    f = fakeframe(bytes, 2, 1, 0x02180014)
    df = decode_frame(f)
    @test df.pixel_format === :RGB8
    @test eltype(df.image) === RGB{N0f8}
    @test size(df.image) == (1, 2)
    p1 = df.image[1, 1]
    @test reinterpret(UInt8, p1.r) == 10
    @test reinterpret(UInt8, p1.g) == 20
    @test reinterpret(UInt8, p1.b) == 30
    p2 = df.image[1, 2]
    @test reinterpret(UInt8, p2.r) == 200
    @test reinterpret(UInt8, p2.g) == 100
    @test reinterpret(UInt8, p2.b) == 50
end

@testset "PixelFormats: BGR8" begin
    bytes = UInt8[30, 20, 10, 50, 100, 200]   # B,G,R for pix0=(10,20,30)
    f = fakeframe(bytes, 2, 1, 0x02180015)
    df = decode_frame(f)
    @test eltype(df.image) === BGR{N0f8}
    p1 = df.image[1, 1]
    @test reinterpret(UInt8, p1.r) == 10
    @test reinterpret(UInt8, p1.g) == 20
    @test reinterpret(UInt8, p1.b) == 30
end

@testset "PixelFormats: RGBa8" begin
    bytes = UInt8[1, 2, 3, 255, 4, 5, 6, 128]
    f = fakeframe(bytes, 2, 1, 0x02200016)
    df = decode_frame(f)
    @test eltype(df.image) === RGBA{N0f8}
    p = df.image[1, 1]
    @test reinterpret(UInt8, p.r) == 1
    @test reinterpret(UInt8, p.g) == 2
    @test reinterpret(UInt8, p.b) == 3
    @test reinterpret(UInt8, p.alpha) == 255
end

@testset "PixelFormats: RGB16" begin
    # 1 pixel, 3 channels × 2 bytes LE: R=0x4000, G=0x8000, B=0xFFFF
    bytes = UInt8[0x00, 0x40, 0x00, 0x80, 0xFF, 0xFF]
    f = fakeframe(bytes, 1, 1, 0x02300033)
    df = decode_frame(f)
    @test eltype(df.image) === RGB{N0f16}
    p = df.image[1, 1]
    @test reinterpret(UInt16, p.r) == 0x4000
    @test reinterpret(UInt16, p.g) == 0x8000
    @test reinterpret(UInt16, p.b) == 0xFFFF
end

@testset "PixelFormats: RGB10p32 (10 bits per channel packed in 32-bit word)" begin
    # 1 pixel: R=1023, G=512, B=0  →  word = (0 << 20) | (512 << 10) | 1023
    raw = UInt32(0) << 20 | UInt32(512) << 10 | UInt32(1023)
    bytes = UInt8[
        UInt8(raw & 0xFF),
        UInt8((raw >> 8)  & 0xFF),
        UInt8((raw >> 16) & 0xFF),
        UInt8((raw >> 24) & 0xFF),
    ]
    f = fakeframe(bytes, 1, 1, 0x0220001D)
    df = decode_frame(f)
    @test df.pixel_format === :RGB10p32
    @test eltype(df.image) === RGB{N0f16}
    p = df.image[1, 1]
    @test reinterpret(UInt16, p.r) == UInt16(1023) << 6
    @test reinterpret(UInt16, p.g) == UInt16(512)  << 6
    @test reinterpret(UInt16, p.b) == UInt16(0)    << 6
end
