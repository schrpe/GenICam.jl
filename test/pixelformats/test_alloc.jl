using Test
using GenICam
using GenICam.PixelFormats
using ColorTypes
using FixedPointNumbers

# Allocation budget regression test for the streaming hot path.  Every
# decoder must allocate at most one Matrix{T}(undef, h, w) — the older
# `permutedims(reshape(...))` idiom paid two and showed up as 600+ MB/s of
# garbage on a live stream, triggering GC stalls visible as frame-rate
# drops.  This test locks in the single-allocation budget so a future
# refactor cannot silently reintroduce the temporary vector.

# Reuse the Mono10p quartet packer from test_mono.jl if it's already loaded;
# otherwise inline a copy here so this file works standalone.
if !isdefined(Main, :_pack_mono10p_quartet)
    function _pack_mono10p_quartet(p0::Integer, p1::Integer, p2::Integer, p3::Integer)
        p0 = UInt16(p0); p1 = UInt16(p1); p2 = UInt16(p2); p3 = UInt16(p3)
        b0 = UInt8(p0 & 0xFF)
        b1 = UInt8(((p0 >> 8) & 0x03) | ((p1 & 0x3F) << 2))
        b2 = UInt8(((p1 >> 6) & 0x0F) | ((p2 & 0x0F) << 4))
        b3 = UInt8(((p2 >> 4) & 0x3F) | ((p3 & 0x03) << 6))
        b4 = UInt8((p3 >> 2) & 0xFF)
        return UInt8[b0, b1, b2, b3, b4]
    end
end

@testset "PixelFormats: Mono8 single-allocation budget" begin
    w, h = 64, 64
    bytes = rand(UInt8, w * h)
    f = fakeframe(bytes, w, h, 0x01080001)
    decode_frame(f)                                  # warm up
    allocated = @allocated decode_frame(f)
    # Budget: one Matrix{Gray{N0f8}}(undef, h, w) plus DecodedFrame struct +
    # a small overhead (array header, type tag).  Any second full-image
    # allocation would push this well above 4 KB on top of the 4 KB pixel
    # buffer.
    @test allocated <= sizeof(Gray{N0f8}) * w * h + 256
end

@testset "PixelFormats: Mono10p single-allocation budget" begin
    w, h = 16, 16                              # 256 pixels = 64 quartets
    bytes = UInt8[]
    k = UInt16(0)
    for _ in 1:64
        append!(bytes, _pack_mono10p_quartet(k & 0x3FF, (k+1) & 0x3FF,
                                             (k+2) & 0x3FF, (k+3) & 0x3FF))
        k += 4
    end
    f = fakeframe(bytes, w, h, 0x010A0046)
    decode_frame(f)                                  # warm up
    allocated = @allocated decode_frame(f)
    # Budget: one Matrix{Gray{N0f16}}(undef, 16, 16) = 512 bytes payload +
    # struct overhead.  Any temporary Vector{Gray{N0f16}} would double this.
    @test allocated <= sizeof(Gray{N0f16}) * w * h + 256
end

@testset "PixelFormats: Mono12p single-allocation budget" begin
    w, h = 16, 16
    bytes = UInt8[]
    k = UInt16(0)
    for _ in 1:128                                   # 128 pairs = 256 pixels
        p0 = k & 0x0FFF; p1 = (k + 1) & 0x0FFF
        push!(bytes, UInt8(p0 & 0xFF))
        push!(bytes, UInt8(((p0 >> 8) & 0x0F) | ((p1 & 0x0F) << 4)))
        push!(bytes, UInt8((p1 >> 4) & 0xFF))
        k += 2
    end
    f = fakeframe(bytes, w, h, 0x010C0047)
    decode_frame(f)
    allocated = @allocated decode_frame(f)
    @test allocated <= sizeof(Gray{N0f16}) * w * h + 256
end

@testset "PixelFormats: RGB8 single-allocation budget" begin
    w, h = 32, 32
    bytes = rand(UInt8, 3 * w * h)
    f = fakeframe(bytes, w, h, 0x02180014)
    decode_frame(f)
    allocated = @allocated decode_frame(f)
    @test allocated <= sizeof(RGB{N0f8}) * w * h + 256
end
