using Test
using GenICam
using GenICam.PixelFormats

@testset "PixelFormats: registry lookup by code" begin
    # Mono8 — registered under multiple namespaces; all should resolve.
    for ns in (UInt64(0), UInt64(1), UInt64(4))
        spec = spec_for_code(ns, 0x01080001)
        @test spec !== nothing
        @test spec.name === :Mono8
        @test spec.bits_per_pixel == 8
        @test spec.family === :mono
        @test spec.cfa === :none
    end

    # Unknown code -> nothing
    @test spec_for_code(UInt64(0), UInt64(0xDEADBEEF)) === nothing
end

@testset "PixelFormats: registry lookup by name" begin
    @test spec_for_name(:Mono8) !== nothing
    @test spec_for_name(:BayerRG8).cfa === :RGGB
    @test spec_for_name(:BayerGB12p).bits_per_pixel == 12
    @test spec_for_name(:RGB10p32).family === :rgb
    @test spec_for_name(:Nonsense) === nothing
end

@testset "PixelFormats: spec consistency (cfa↔family alignment)" begin
    for spec in values(PFNC_FORMATS)
        if spec.family === :bayer
            @test spec.cfa in (:GRBG, :RGGB, :GBRG, :BGGR)
        else
            @test spec.cfa === :none
        end
        @test spec.bits_per_pixel > 0
    end
end

@testset "PixelFormats: UnsupportedPixelFormat surfaces with hint" begin
    using GenICam.GenTL: Frame
    bytes = UInt8[0]
    f = Frame(C_NULL, bytes, Csize_t(1), Csize_t(1), Csize_t(1),
        UInt64(0xDEADBEEF), UInt64(0), false)
    @test_throws PixelFormats.UnsupportedPixelFormat decode_frame(f)
    @test_throws PixelFormats.UnsupportedPixelFormat decode_frame(f;
        pixel_format_hint = :Nonsense)
end
