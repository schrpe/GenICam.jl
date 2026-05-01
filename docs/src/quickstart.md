```@meta
CurrentModule = GenICam
```

# Quickstart

This page walks through everything from a fresh Julia REPL to a
displayed image. About 5 minutes if a camera and producer are already
installed; about 30 minutes if you're starting from scratch.

## 1. Install a GenTL Producer

`GenICam.jl` is a *consumer*. It needs a *producer* — a vendor-supplied
DLL (file extension `.cti`) that talks to your camera over its physical
transport (GigE Vision, USB3 Vision, Camera Link, CoaXPress, ...). You
get one from any vendor's SDK; the producers below have been tested
with this package:

| Producer | Source | Targets |
|---|---|---|
| Balluff `mvGenTLProducer.cti` | [Balluff Impact Acquire](https://www.balluff.com) | GigE Vision, USB3 Vision |
| MATRIX VISION mvIMPACT producer | [MATRIX VISION website](https://www.matrix-vision.com) | GigE / USB3 Vision |
| Basler GenTL producer | Basler pylon SDK | Basler cameras |
| Stemmer Common Vision Blox producer | [Stemmer Imaging](https://www.stemmer-imaging.com) | various |

Most installers set the `GENICAM_GENTL64_PATH` environment variable for
you. Verify with:

```julia
ENV["GENICAM_GENTL64_PATH"]
# "C:\\Program Files\\Balluff\\ImpactAcquire\\bin\\x64"
```

If it's empty or missing, point it at the directory containing the
`.cti` file. Multiple paths are separated by `;` on Windows or `:` on
Linux/macOS.

## 2. Install GenICam.jl

```julia
using Pkg
Pkg.add(url = "https://github.com/schrpe/GenICam.jl")
```

(Once the package is registered the URL form will be unnecessary.)

## 3. Find a producer and a camera

```julia
using GenICam, GenICam.GenTL

list_producers()
# Vector{String}:
#   "C:\\Program Files\\Balluff\\ImpactAcquire\\bin\\x64\\mvGenTLProducer.cti"
#   "C:\\Program Files\\Balluff\\ImpactAcquire\\bin\\x64\\mvGenTLProducer.PCIe.cti"

list_all_cameras()
# 1-element Vector{...}:
#   (producer_path = ".../mvGenTLProducer.cti",
#    interface     = InterfaceInfo(...U3V),
#    device        = DeviceInfo("F0700035", "MATRIX VISION GmbH",
#                               "mvBlueFOX3-1013C", ...))
```

[`list_all_cameras`](@ref) walks every installed producer; useful when
you're not sure which one your camera lives behind. For a single known
producer use [`list_cameras`](@ref):

```julia
api = load_producer(first(list_producers()))
producer = Producer(api)
list_cameras(producer)
```

## 4. Open the camera

```julia
info = first(list_cameras(producer))
cam = open_camera(producer, info.interface, info.device)
# Camera(F0700035, 1184 nodes)
```

`open_camera` does several things in one call:

  1. Opens the camera's transport (GigE / USB3 channel).
  2. Opens a data stream on it.
  3. Downloads the GenApi XML from the camera (often ZIP-compressed,
     several hundred KB).
  4. Parses the XML into a `Nodemap` — a graph of feature nodes that
     describes every register, formula, and selector chain.
  5. Returns a `Camera` bundling all of the above.

## 5. Read and write features

The simplest way is property syntax. Tab-completion works in the REPL:

```julia
cam.Width = 640
cam.Height = 480
cam.PixelFormat = "Mono8"
cam.ExposureTime           # 20000.0  (microseconds)
cam.DeviceVendorName       # "MATRIX VISION GmbH"
```

Behind the scenes this calls [`set_feature!`](@ref) / [`get_feature`](@ref).
You can also call those directly:

```julia
set_feature!(cam, :Width, 640)
get_feature(cam, "Width")
execute_command!(cam, :TriggerSoftware)
```

Both spellings work, both spellings are supported. Property syntax is
shorter; the explicit calls are easier to grep for in scripts and skip
property-name validation (no surprise when a feature name happens to
match a Julia field name).

## 6. Set up an acquisition

The seven SFNC mandatories — Width, Height, PixelFormat, PayloadSize,
AcquisitionMode, AcquisitionStart, AcquisitionStop — are enough for a
basic capture. Most cameras also expose ExposureTime, Gain, and
trigger-related features; the SFNC convenience helpers configure them
in the right order:

```julia
set_aoi!(cam; x = 0, y = 0, width = 640, height = 480)
set_exposure!(cam, 10_000.0)        # microseconds
set_gain!(cam, 0.0)                  # decibels
disable_trigger!(cam)                # free-running
cam.PixelFormat = "Mono8"
```

See **[Features](@ref)** for the full feature-access reference.

## 7. Grab one frame

```julia
frame = grab(cam; timeout_ms = 1000)
# DecodedFrame{Matrix{Gray{N0f8}}}(Mono8, 480x640)

frame.image     # Matrix{Gray{N0f8}} of size (480, 640)
frame.pixel_format    # :Mono8
```

[`grab`](@ref) returns a [`DecodedFrame`](@ref) — a thin wrapper
carrying the typed Julia array plus metadata (pixel-format symbol, CFA
pattern for Bayer images). For raw bytes use [`grab_raw`](@ref).

The matrix is column-major and indexed `(row, col)` — `frame.image[1, 1]`
is the top-left pixel.

## 8. Stream continuously

```julia
stream(cam; num_buffers = 8) do channel
    for img in Iterators.take(channel, 100)
        process(img.image)
    end
end
```

[`stream`](@ref) spawns a background task that pushes decoded frames
into a `Channel`. The do-block guarantees [`stop_stream`](@ref) is
called even if your loop throws.

See **[Streaming](@ref)** for backpressure policies, statistics, and
the explicit `start_stream` / `stop_stream` form.

## 9. Close cleanly

```julia
close(cam)         # tears down stream / event pump / data stream / interface
close(producer)
close(api)
```

Finalizers also clean up if you forget — but explicit `close` is
recommended in long-running programs so the camera is released
promptly.

## 10. Putting it all together

A complete script:

```julia
using GenICam, GenICam.GenTL

api      = load_producer(first(list_producers()))
producer = Producer(api)
info     = first(list_cameras(producer))
cam      = open_camera(producer, info.interface, info.device)

try
    set_aoi!(cam; width = 640, height = 480)
    cam.PixelFormat = "Mono8"
    set_exposure!(cam, 5000.0)

    stream(cam) do channel
        for (i, img) in enumerate(Iterators.take(channel, 30))
            stats = (mean = sum(img.image) / length(img.image),
                     min  = minimum(img.image),
                     max  = maximum(img.image))
            @info "frame" i stats
        end
    end
finally
    close(cam); close(producer); close(api)
end
```

That's everything you need for free-running 30-frame acquisition with
proper cleanup. From here, browse the topical pages to dig deeper into
the parts you care about.
