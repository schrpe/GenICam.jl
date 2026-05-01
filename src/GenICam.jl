"""
    GenICam

Pure-Julia implementation of the EMVA GenICam standard family.

The package implements the consumer side of all four GenICam pieces:

  * `GenTL` — binding for the GenTL Standard 1.5 Producer C API; loads
    any vendor `.cti` DLL via `Libdl`.
  * `GenApi` — full node-map: 15 concrete node types, 3-pass parser
    with forward-reference / invalidator wiring, SwissKnife
    expression evaluator, caching, `<pIsAvailable>` / `<pIsImplemented>`
    predicates, `<Streamable>` save / load.
  * `PixelFormats` — PFNC decoders to typed Julia matrices
    (`Gray{N0fX}` / `RGB{N0fX}` / `BGR{N0fX}` / ...).
  * `Camera` — the high-level handle: `cam.Width = 640`, `grab(cam)`,
    `stream(cam) do ch ... end`, plus SFNC convenience helpers and
    chunk / event / hot-plug layers.
"""
module GenICam

include("GenTL/GenTL.jl")
using .GenTL

include("GenApi/GenApi.jl")
using .GenApi

include("PixelFormats/PixelFormats.jl")
using .PixelFormats

include("Camera.jl")
include("chunks.jl")
include("events.jl")
include("streaming.jl")
include("sfnc.jl")
include("hotplug.jl")

export GenTL, GenApi, PixelFormats,
    Camera, open_camera, list_cameras,
    get_feature, set_feature!, execute_command!, grab, grab_raw,
    DecodedFrame,
    # SFNC convenience
    set_aoi!, reset_aoi!, set_trigger!, disable_trigger!,
    set_exposure!, set_gain!,
    features, categories, features_in,
    # Streaming
    StreamHandle, StreamPolicy, DROP_OLDEST, DROP_NEWEST, BLOCK,
    start_stream, stop_stream, stream,
    is_streaming, frames_grabbed, frames_dropped,
    # Chunks
    ChunkBinding, chunk_features, enable_chunks!, disable_chunks!,
    decode_chunks!, last_chunks,
    # Events
    FeatureEvent, ListenerHandle,
    on_feature_invalidate, on_feature_change, remove_listener,
    close_event_pump!,
    # Hot-plug
    DeviceEvent, list_all_cameras,
    watch_devices, watch_all_producers, stop_watch!

end # module
