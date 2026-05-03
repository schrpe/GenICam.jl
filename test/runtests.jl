using Test
using GenICam
using GenICam.GenTL
using GenICam.GenApi

const FIXTURES = joinpath(@__DIR__, "fixtures")

@testset "GenICam.jl" begin

    @testset "GenApi: byte-level codec" begin
        # round-trip unsigned little-endian
        bytes = GenApi._encode_int(0x12345678, 4,
            GenApi.LITTLE_ENDIAN, GenApi.UNSIGNED)
        @test bytes == UInt8[0x78, 0x56, 0x34, 0x12]
        @test GenApi._decode_int(bytes, GenApi.LITTLE_ENDIAN,
            GenApi.UNSIGNED) == 0x12345678

        # big-endian
        be = GenApi._encode_int(0x12345678, 4,
            GenApi.BIG_ENDIAN, GenApi.UNSIGNED)
        @test be == UInt8[0x12, 0x34, 0x56, 0x78]
        @test GenApi._decode_int(be, GenApi.BIG_ENDIAN,
            GenApi.UNSIGNED) == 0x12345678

        # signed sign-extension on a 4-byte negative value
        neg = GenApi._encode_int(-1, 4, GenApi.LITTLE_ENDIAN, GenApi.SIGNED)
        @test neg == UInt8[0xFF, 0xFF, 0xFF, 0xFF]
        @test GenApi._decode_int(neg, GenApi.LITTLE_ENDIAN, GenApi.SIGNED) == -1

        # 2-byte negative round-trip
        neg2 = GenApi._encode_int(-2, 2, GenApi.LITTLE_ENDIAN, GenApi.SIGNED)
        @test neg2 == UInt8[0xFE, 0xFF]
        @test GenApi._decode_int(neg2, GenApi.LITTLE_ENDIAN, GenApi.SIGNED) == -2
    end

    @testset "GenApi: local URL parsing" begin
        # legacy semicolon form
        @test GenApi._parse_local_url("Local:foo.xml;ABCD;EF12") ==
            ("foo.xml", UInt64(0xABCD), UInt64(0xEF12))
        @test GenApi._parse_local_url("local:bar.zip;0x1000;0x200") ==
            ("bar.zip", UInt64(0x1000), UInt64(0x200))

        # URI form
        fn, addr, sz = GenApi._parse_local_url(
            "local:///cam.xml?addr=0xDEADBEEF&size=0x42")
        @test fn == "cam.xml"
        @test addr == UInt64(0xDEADBEEF)
        @test sz == UInt64(0x42)

        # malformed → ArgumentError
        @test_throws ArgumentError GenApi._parse_local_url(
            "http://example/cam.xml")
    end

    @testset "GenApi: parse fixture XML" begin
        xml = read(joinpath(FIXTURES, "minimal_camera.xml"), String)
        nm = GenApi.parse_nodemap(xml)

        # all seven mandatories plus auxiliary nodes are in the map
        for name in ("Width", "Height", "PixelFormat", "PayloadSize",
                     "AcquisitionMode", "AcquisitionStart", "AcquisitionStop",
                     "WidthReg", "HeightReg", "PixelFormatReg")
            @test haskey(nm, name)
        end

        # feature-grade names show up in feature_names (Integer/Enum/Command)
        @test "Width" in nm.feature_names
        @test "PixelFormat" in nm.feature_names
        @test "AcquisitionStart" in nm.feature_names
        # registers themselves are not exposed as features
        @test !("WidthReg" in nm.feature_names)

        # Integer with pValue indirection
        w = nm["Width"]
        @test w isa GenApi.IntegerNode
        @test w.pvalue == "WidthReg"
        @test w.minimum == 1
        @test w.maximum == 1920

        # IntReg metadata
        wr = nm["WidthReg"]
        @test wr isa GenApi.IntRegNode
        @test wr.address == 0x10000
        @test wr.length == 4
        @test wr.endianess === GenApi.LITTLE_ENDIAN
        @test wr.sign === GenApi.UNSIGNED
        @test wr.access === GenApi.ACC_RW

        # BigEndian register flagged correctly
        hr = nm["HeightReg"]
        @test hr isa GenApi.IntRegNode
        @test hr.endianess === GenApi.BIG_ENDIAN

        # Enumeration with three entries
        pf = nm["PixelFormat"]
        @test pf isa GenApi.EnumerationNode
        @test pf.pvalue == "PixelFormatReg"
        @test length(pf.entries) == 3
        names = [e.name for e in pf.entries]
        @test "Mono8" in names
        @test "RGB8" in names
        @test pf.entries[findfirst(e -> e.name == "Mono8", pf.entries)].value ==
            0x01080001

        # Command
        cmd = nm["AcquisitionStart"]
        @test cmd isa GenApi.CommandNode
        @test cmd.pvalue == "AcquisitionStartReg"
        @test cmd.command_value == 1

        # MaskedIntReg with LSB/MSB
        sb = nm["StatusBitFlag"]
        @test sb isa GenApi.MaskedIntRegNode
        @test sb.lsb == 4
        @test sb.msb == 7
    end

    @testset "GenApi: unknown vendor tags are skipped silently" begin
        # A vendor-specific tag at the top level shouldn't break the parser
        # — known nodes around it should still appear in the nodemap.
        bad = """
        <RegisterDescription xmlns="http://www.genicam.org/GenApi/Version_1_1"
                             SchemaMajorVersion="1" SchemaMinorVersion="1"
                             SchemaSubMinorVersion="0">
            <SomeVendorTag>arbitrary content</SomeVendorTag>
            <IntReg Name="OkReg">
                <Address>0x1000</Address>
                <Length>4</Length>
                <AccessMode>RW</AccessMode>
                <pPort>Device</pPort>
                <Sign>Unsigned</Sign>
                <Endianess>LittleEndian</Endianess>
            </IntReg>
        </RegisterDescription>
        """
        nm = GenApi.parse_nodemap(bad)
        @test haskey(nm, "OkReg")
        @test !haskey(nm, "SomeVendorTag")
    end

    @testset "GenApi: <pAddress> indirection resolves" begin
        # The parser supports <pAddress> — the IntReg should land in the nodemap
        # with both the literal Address and the pAddress contribution recorded.
        ok = """
        <RegisterDescription xmlns="http://www.genicam.org/GenApi/Version_1_1"
                             SchemaMajorVersion="1" SchemaMinorVersion="1"
                             SchemaSubMinorVersion="0">
            <IntReg Name="DynamicReg">
                <Address>0x100</Address>
                <pAddress>BaseReg</pAddress>
                <Length>4</Length>
                <AccessMode>RW</AccessMode>
                <pPort>Device</pPort>
                <Sign>Unsigned</Sign>
                <Endianess>LittleEndian</Endianess>
            </IntReg>
        </RegisterDescription>
        """
        nm = GenApi.parse_nodemap(ok)
        @test haskey(nm, "DynamicReg")
        # The address_spec carries the literal contribution PLUS the pAddress ref.
        @test length(nm["DynamicReg"].address_spec.terms) == 2
    end

    @testset "GenTL: producer discovery" begin
        # Just verify the function returns a Vector{String}; the contents
        # depend on what the test machine has installed.
        @test list_producers() isa Vector{String}
    end

    @testset "PixelFormats" begin
        include(joinpath(@__DIR__, "pixelformats", "_helpers.jl"))
        include(joinpath(@__DIR__, "pixelformats", "test_lookup.jl"))
        include(joinpath(@__DIR__, "pixelformats", "test_mono.jl"))
        include(joinpath(@__DIR__, "pixelformats", "test_bayer.jl"))
        include(joinpath(@__DIR__, "pixelformats", "test_rgb.jl"))
        include(joinpath(@__DIR__, "pixelformats", "test_yuv.jl"))
        include(joinpath(@__DIR__, "pixelformats", "test_alloc.jl"))
    end

    @testset "GenApi internals" begin
        include(joinpath(@__DIR__, "genapi", "test_registers.jl"))
        include(joinpath(@__DIR__, "genapi", "test_formula.jl"))
    end

    @testset "Cross-platform path handling" begin
        include(joinpath(@__DIR__, "test_paths.jl"))
    end

    @testset "GenTL: live producer (skipped if none installed)" begin
        prods = list_producers()
        if isempty(prods)
            @info "no GenTL producer found; skipping live integration test"
            @test true  # keep the testset non-empty
        else
            path = first(prods)
            api = load_producer(path)
            try
                p = Producer(api)
                try
                    @test producer_info(p, TL_INFO_VENDOR) != ""
                    ifaces = list_interfaces(p)
                    @test ifaces isa Vector{InterfaceInfo}
                finally
                    close(p)
                end
            finally
                close(api)
            end
        end
    end

end
