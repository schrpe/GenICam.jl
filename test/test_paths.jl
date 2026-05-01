using Test
using GenICam
using GenICam.GenTL

@testset "GenTL: path separator picked correctly per OS" begin
    sep = GenTL._PATH_SEPARATOR
    if Sys.iswindows()
        @test sep == ';'
    else
        @test sep == ':'
    end
end

@testset "GenTL: list_producers returns Vector{String}" begin
    # Whatever the host has installed, the function must return a Vector
    # without throwing. CI runners usually have nothing installed → empty.
    @test list_producers() isa Vector{String}
end

@testset "GenTL: list_producers parses the env var per platform" begin
    # Stash the real env var and restore it after the test.
    saved = get(ENV, "GENICAM_GENTL64_PATH", nothing)
    try
        # Point at a temp directory containing a fake .cti file.
        d = mktempdir()
        fake = joinpath(d, "fake_producer.cti")
        write(fake, "not a real DLL")          # content irrelevant — list_producers just listdir's

        sep = GenTL._PATH_SEPARATOR
        ENV["GENICAM_GENTL64_PATH"] = string(d, sep, "/nonexistent/dir")

        prods = list_producers()
        @test fake in prods
        @test length(prods) >= 1

        # Empty env var → empty result on Windows / Linux. (macOS may still
        # find /Library/Frameworks producers, so don't assert emptiness there.)
        ENV["GENICAM_GENTL64_PATH"] = ""
        if !Sys.isapple()
            @test isempty(list_producers())
        else
            @test list_producers() isa Vector{String}
        end
    finally
        if saved === nothing
            delete!(ENV, "GENICAM_GENTL64_PATH")
        else
            ENV["GENICAM_GENTL64_PATH"] = saved
        end
    end
end

@testset "GenTL: list_producers uppercase .CTI extension" begin
    # Some installers ship `.CTI` (uppercase) — our matcher is
    # case-insensitive via lowercase() so it should pick those up too.
    saved = get(ENV, "GENICAM_GENTL64_PATH", nothing)
    try
        d = mktempdir()
        upper = joinpath(d, "FakeProducer.CTI")
        write(upper, "")
        ENV["GENICAM_GENTL64_PATH"] = d
        @test upper in list_producers()
    finally
        if saved === nothing
            delete!(ENV, "GENICAM_GENTL64_PATH")
        else
            ENV["GENICAM_GENTL64_PATH"] = saved
        end
    end
end
