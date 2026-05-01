using Test
using GenICam
using GenICam.GenApi
using GenICam.GenApi: AddressTerm, AddressSpec, _resolve_address,
    _decode_int, _encode_int, LITTLE_ENDIAN, BIG_ENDIAN, SIGNED, UNSIGNED

@testset "GenApi.registers: codec round-trip" begin
    # 4-byte unsigned LE
    bytes = _encode_int(0x12345678, 4, LITTLE_ENDIAN, UNSIGNED)
    @test bytes == UInt8[0x78, 0x56, 0x34, 0x12]
    @test _decode_int(bytes, LITTLE_ENDIAN, UNSIGNED) == 0x12345678

    # 4-byte BE
    be = _encode_int(0x12345678, 4, BIG_ENDIAN, UNSIGNED)
    @test be == UInt8[0x12, 0x34, 0x56, 0x78]
    @test _decode_int(be, BIG_ENDIAN, UNSIGNED) == 0x12345678

    # Signed extension
    neg = _encode_int(-1, 4, LITTLE_ENDIAN, SIGNED)
    @test neg == UInt8[0xFF, 0xFF, 0xFF, 0xFF]
    @test _decode_int(neg, LITTLE_ENDIAN, SIGNED) == -1

    # 2-byte signed
    @test _decode_int(_encode_int(-2, 2, LITTLE_ENDIAN, SIGNED),
        LITTLE_ENDIAN, SIGNED) == -2

    # 8-byte covers the full Int64 range (no sign-extend overflow path)
    @test _decode_int(_encode_int(typemin(Int64), 8, LITTLE_ENDIAN, SIGNED),
        LITTLE_ENDIAN, SIGNED) == typemin(Int64)
end

@testset "GenApi.registers: AddressSpec literal" begin
    spec = AddressSpec(0x1000)
    addr = _resolve_address(spec, name -> error("no refs expected"))
    @test addr == 0x1000
end

@testset "GenApi.registers: AddressSpec with pAddress (sum)" begin
    # base + offset → sum of contributions
    spec = AddressSpec([
        AddressTerm(0x1000),
        AddressTerm("BaseReg"),
    ])
    table = Dict("BaseReg" => 0x500)
    addr = _resolve_address(spec, name -> table[name])
    @test addr == 0x1500
end

@testset "GenApi.registers: AddressSpec with pIndex (multiplied offset)" begin
    # base + (selected_index × offset)
    spec = AddressSpec([
        AddressTerm(0x1000),
        AddressTerm("Selector", 8),
    ])
    table = Dict("Selector" => 3)
    @test _resolve_address(spec, name -> table[name]) == 0x1000 + 3 * 8

    # Index 0 keeps base address
    table2 = Dict("Selector" => 0)
    @test _resolve_address(spec, name -> table2[name]) == 0x1000
end

@testset "GenApi.registers: AddressSpec composition (pAddress + pIndex + literal)" begin
    spec = AddressSpec([
        AddressTerm(0x1000),
        AddressTerm("BaseReg"),
        AddressTerm("Selector", 16),
    ])
    table = Dict("BaseReg" => 0x500, "Selector" => 2)
    @test _resolve_address(spec, name -> table[name]) == 0x1000 + 0x500 + 2 * 16
end

@testset "GenApi.registers: AddressTerm convenience constructors" begin
    @test AddressTerm(0x42).kind === :literal
    @test AddressTerm("Foo").kind === :pnode
    @test AddressTerm("Foo").ref == "Foo"
    @test AddressTerm("Foo", 8).kind === :pindex
    @test AddressTerm("Foo", 8).offset == 8
end
