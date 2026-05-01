using Test
using GenICam
using GenICam.PixelFormats
using ColorTypes
using FixedPointNumbers

# Reference YUV→RGB conversion (matches the integer-fixed-point form in
# decoders.jl) so we don't enshrine our own bug as the spec.
function _ref_yuv(y::Integer, cb::Integer, cr::Integer)
    yi = Int(y); cbi = Int(cb) - 128; cri = Int(cr) - 128
    r = clamp(yi + ((1436 * cri) >> 10), 0, 255)
    g = clamp(yi - ((352 * cbi + 731 * cri) >> 10), 0, 255)
    b = clamp(yi + ((1814 * cbi) >> 10), 0, 255)
    return (UInt8(r), UInt8(g), UInt8(b))
end

@testset "PixelFormats: YUV422_8_UYVY" begin
    # 2 pixels, byte order [U, Y0, V, Y1].  Pick a bright neutral grey.
    bytes = UInt8[128, 200, 128, 50]
    f = fakeframe(bytes, 2, 1, 0x0210001F)
    df = decode_frame(f)
    @test df.pixel_format === :YUV422_8_UYVY
    @test eltype(df.image) === RGB{N0f8}
    @test size(df.image) == (1, 2)
    r0, g0, b0 = _ref_yuv(200, 128, 128)
    r1, g1, b1 = _ref_yuv(50,  128, 128)
    p0 = df.image[1, 1]; p1 = df.image[1, 2]
    @test reinterpret(UInt8, p0.r) == r0
    @test reinterpret(UInt8, p0.g) == g0
    @test reinterpret(UInt8, p0.b) == b0
    @test reinterpret(UInt8, p1.r) == r1
    @test reinterpret(UInt8, p1.g) == g1
    @test reinterpret(UInt8, p1.b) == b1
end

@testset "PixelFormats: YUV422_8 (YUYV byte order)" begin
    bytes = UInt8[200, 128, 50, 128]   # Y0, U, Y1, V
    f = fakeframe(bytes, 2, 1, 0x02100032)
    df = decode_frame(f)
    @test df.pixel_format === :YUV422_8
    p0 = df.image[1, 1]; p1 = df.image[1, 2]
    r0, g0, b0 = _ref_yuv(200, 128, 128)
    r1, g1, b1 = _ref_yuv(50,  128, 128)
    @test (reinterpret(UInt8, p0.r), reinterpret(UInt8, p0.g),
           reinterpret(UInt8, p0.b)) == (r0, g0, b0)
    @test (reinterpret(UInt8, p1.r), reinterpret(UInt8, p1.g),
           reinterpret(UInt8, p1.b)) == (r1, g1, b1)
end
