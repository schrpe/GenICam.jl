"""
GenTL Producer (.cti) loading and discovery.

A GenTL Producer is a vendor-supplied DLL that implements the GenTL Standard.
On every supported OS the file extension is `.cti` (a renamed `.dll` on
Windows, `.so` on Linux, `.dylib` on macOS). Discovery is via the
`GENICAM_GENTL64_PATH` environment variable: a list of directories
separated by `;` on Windows or `:` on POSIX.

Cross-platform notes:

  * `Libdl.dlopen` accepts a `.cti` file when given an absolute path on
    every supported OS — the loader trusts the path rather than enforcing
    a `.so` / `.dylib` extension.
  * x86_64 Linux/macOS use the SysV ABI; Windows x64 uses MS x64. Both are
    a single calling convention with no `__stdcall` decoration on x64, so
    `ccall` works identically.
  * macOS may also place producer libraries under `/Library/Frameworks` or
    `~/Library/Frameworks`; we probe those when `GENICAM_GENTL64_PATH` is
    missing or empty.
"""

const _PATH_SEPARATOR = Sys.iswindows() ? ';' : ':'

"""
    list_producers() -> Vector{String}

Scan every directory listed in `GENICAM_GENTL64_PATH` for `*.cti` files and
return their absolute paths. Missing or empty directories are skipped
silently. On macOS, additionally probes `/Library/Frameworks` and
`~/Library/Frameworks` as fallback locations.
"""
function list_producers()
    raw = get(ENV, "GENICAM_GENTL64_PATH", "")
    out = String[]
    if !isempty(raw)
        for dir in split(raw, _PATH_SEPARATOR; keepempty = false)
            _scan_dir!(out, String(strip(dir)))
        end
    end
    if Sys.isapple()
        # Vendors sometimes ship producers as macOS frameworks; the .cti
        # lives at <Framework>/Versions/A/<Name>.cti or similar. Walk the
        # standard framework directories.
        for base in (joinpath(homedir(), "Library", "Frameworks"),
                     "/Library/Frameworks")
            isdir(base) && _scan_frameworks!(out, base)
        end
    end
    return out
end

@inline function _scan_dir!(out::Vector{String}, dir::AbstractString)
    isdir(dir) || return
    for f in readdir(dir)
        endswith(lowercase(f), ".cti") && push!(out, joinpath(dir, f))
    end
    return
end

# macOS framework layout: <Foo.framework>/Versions/<A>/<Foo>.cti
function _scan_frameworks!(out::Vector{String}, base::AbstractString)
    for name in readdir(base)
        endswith(name, ".framework") || continue
        versions = joinpath(base, name, "Versions")
        isdir(versions) || continue
        for ver in readdir(versions)
            _scan_dir!(out, joinpath(versions, ver))
        end
    end
    return
end

"""
    load_producer(path) -> ProducerAPI

Open a GenTL producer DLL, resolve all required exports, and call `GCInitLib`.
The returned `ProducerAPI` owns the dlopen handle and must be closed via
`unload_producer` (or it will be closed automatically by the finalizer).
"""
function load_producer(path::AbstractString)
    isfile(path) || throw(ArgumentError("GenTL producer not found: $path"))
    dlh = Libdl.dlopen(path, Libdl.RTLD_LAZY)
    api = ProducerAPI(
        String(path),
        dlh,
        false,
        # placeholder pointers, overwritten by _resolve_symbols!
        ntuple(_ -> C_NULL, length(_GENTL_SYMBOLS))...,
    )
    try
        _resolve_symbols!(api)
        gc_init_lib(api)
        api.initialized = true
    catch
        Libdl.dlclose(dlh)
        rethrow()
    end
    finalizer(unload_producer, api)
    return api
end

"""
    unload_producer(api)

Tear down a producer: `GCCloseLib` if it was initialized, then `dlclose` the
library. Safe to call multiple times — subsequent calls are no-ops.
"""
function unload_producer(api::ProducerAPI)
    api.dlhandle == C_NULL && return nothing
    if api.initialized
        try
            gc_close_lib(api)
        catch
            # finalizer must not throw; swallow late-shutdown errors
        end
        api.initialized = false
    end
    try
        Libdl.dlclose(api.dlhandle)
    catch
    end
    api.dlhandle = C_NULL
    return nothing
end

Base.close(api::ProducerAPI) = unload_producer(api)

function Base.show(io::IO, api::ProducerAPI)
    if api.dlhandle == C_NULL
        print(io, "ProducerAPI(closed, ", basename(api.path), ")")
    else
        print(io, "ProducerAPI(", basename(api.path), ")")
    end
end
