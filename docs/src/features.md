```@meta
CurrentModule = GenICam
```

# Features

A *feature* is a named piece of camera state — `Width`, `ExposureTime`,
`TriggerMode`, `DeviceVendorName`, etc. The camera publishes every
feature it understands in its GenApi XML node-map; `GenICam.jl` parses
that XML on `open_camera` and exposes each feature for read / write /
execute.

If you're new to the GenApi node-map / register-vs-feature distinction,
read [Background: GenApi node-map](concepts.md#GenApi-node-map) first.

## Two API styles

```julia
# Property syntax (the convenience layer)
cam.Width = 640
w = cam.Width
cam.PixelFormat = "Mono8"

# Explicit calls (the core, used internally)
set_feature!(cam, :Width, 640)
w = get_feature(cam, :Width)
set_feature!(cam, "PixelFormat", "Mono8")

# Commands trigger an action — they have no readable value
execute_command!(cam, :AcquisitionStart)
execute_command!(cam, :TriggerSoftware)
```

The two are exact equivalents (the property setter calls
[`set_feature!`](@ref) under the hood). Use whichever reads better in
context.

## Discoverability

```julia
propertynames(cam)        # every feature name as a Symbol
features(cam)              # every feature name as a String
length(cam.nodemap.nodes)  # total number of nodes (>1000 typical)
```

Tab-completion works in the REPL: type `cam.` and press Tab to see all
feature names. The list is built once at `open_camera` time from the
camera's `<Category>` tree (with anything not reachable from `Root`
appended in declaration order).

## Feature types

`get_feature` returns different Julia types depending on the underlying
GenApi node:

| GenApi node | Returns |
|---|---|
| `<Integer>`, `<IntReg>`, `<MaskedIntReg>` | `Int64` |
| `<IntConverter>`, `<IntSwissKnife>` | `Int64` |
| `<Float>`, `<FloatReg>` | `Float64` |
| `<Converter>`, `<SwissKnife>` | `Float64` |
| `<Boolean>` | `Bool` |
| `<String>`, `<StringReg>` | `String` |
| `<Enumeration>` | `String` (the matching `EnumEntry` name) |
| `<Command>` | error — use `execute_command!` instead |

`set_feature!` accepts the natural Julia type plus, for `Enumeration`
nodes, either the entry name (`String` or `Symbol`) or the integer
encoding (`Int64`).

## Categories and visibility

The camera vendor groups features into a tree of `<Category>` nodes for
UI display. You can walk that tree:

```julia
categories(cam)
# Vector{String}: ["AcquisitionControl", "AnalogControl",
#                  "ChunkDataControl", "ColorTransformationControl", ...]

features_in(cam, "AcquisitionControl")
# Vector{String}: ["AcquisitionMode", "ExposureMode", "ExposureTime",
#                  "ExposureAuto", "AcquisitionFrameRate", ...]
```

GenApi marks each feature with a *visibility* level. `:Beginner` is
"every camera GUI shows it"; `:Guru` is "vendor experts only". Filter
with [`features`](@ref):

```julia
features(cam; visibility = :Beginner)             # most-used subset
features(cam; visibility = :Expert)               # superset of Beginner
features(cam; visibility = :Guru)                 # everything except Invisible
features(cam; visibility = :Beginner, category = "AcquisitionControl")
```

The visibility levels nest: `Beginner ⊂ Expert ⊂ Guru ⊂ Invisible`.

## Commands

Some features don't *have* a value — they trigger an action when
"executed":

```julia
execute_command!(cam, :AcquisitionStart)    # start streaming
execute_command!(cam, :AcquisitionStop)     # stop streaming
execute_command!(cam, :TriggerSoftware)     # fire one software trigger
execute_command!(cam, :DeviceReset)         # power-cycle the camera
```

Command nodes raise `ArgumentError` if you try to read them via
`get_feature` — they're intentionally one-way.

## SFNC mandatory features

The Standard Features Naming Convention defines a small set of
features every compliant 2D area-scan camera *must* expose. These are
the bare minimum needed for image acquisition and they're guaranteed
to be present:

| Name | Type | Role |
|---|---|---|
| `Width` | `Integer` | image width in pixels |
| `Height` | `Integer` | image height in pixels |
| `PixelFormat` | `Enumeration` | output pixel layout (PFNC code) |
| `PayloadSize` | `Integer` (RO) | bytes per frame the camera will deliver |
| `AcquisitionMode` | `Enumeration` | `SingleFrame` / `MultiFrame` / `Continuous` |
| `AcquisitionStart` | `Command` | begin acquiring |
| `AcquisitionStop` | `Command` | stop acquiring |

`grab` / `stream` configure those internally; you typically only set
`Width` / `Height` / `PixelFormat` explicitly. Beyond the mandatories,
SFNC also defines a much larger *recommended* set of features grouped
into categories — `AcquisitionControl`, `AnalogControl`,
`ImageFormatControl`, `DigitalIOControl`, `DeviceControl`,
`ChunkDataControl`, `EventControl`, `UserSetControl`, ...

See the [SFNC overview in Background](concepts.md#SFNC:-standard-feature-names)
for the typical patterns (selector chains, Auto/Manual pairs, `*Raw`
legacy fallbacks).

## Selector chains

Multi-channel features (Gain channels, Trigger types, Exposure modes)
follow GenApi's selector pattern: write a selector first, then
read/write the dependent feature. For example:

```julia
cam.GainSelector = "AnalogAll"      # which gain channel are we addressing?
cam.Gain = 6.0                       # set that channel to 6 dB
cam.GainSelector = "DigitalAll"
cam.Gain = 0.0                       # set the *other* channel to 0 dB
```

`<pSelected>` declarations in the camera XML tell `GenICam.jl` which
features depend on which selectors. Writing the selector
auto-invalidates dependent caches so the next read goes to the device.

## Predicates: `<pIsAvailable>`, `<pIsImplemented>`, `<pIsLocked>`

A feature can declare runtime predicates: "I'm only available when
`SomeOtherSwitch` is on", "I'm not implemented on this hardware
variant", etc. `GenICam.jl` evaluates those predicates *before* every
read / write and raises [`GenApi.FeatureNotAvailable`](@ref) when one
returns false.

```julia
try
    cam.mvLiquidLensFocus = 50.0
catch e
    e isa GenApi.FeatureNotAvailable && println("camera doesn't have a liquid lens")
end
```

This is what makes the full-feature walk fast: the parser exposes 654
features on a real mvBlueFOX3, but only ~80% are actually accessible
on a given hardware variant. The rest are rejected before we try to
read absent registers (which would otherwise time out the camera).

## Caching

Reads are cached. The cache is invalidated when:

  * The same feature is written.
  * Any feature listed under the node's `<pInvalidator>` is written.
  * Any selector that reaches the node via `<pSelected>` is written.
  * `EVENT_FEATURE_INVALIDATE` fires for the feature.
  * The whole nodemap is wiped after a write (current pessimistic
    policy — correct but coarse; a future refinement may narrow it).

For per-frame metadata (chunks), the chunk decoder explicitly clears
the binding's cache before each read so per-frame values are fresh.

## SFNC convenience helpers

The seven SFNC mandatories aside, a few feature combos come up so often
that thin wrappers are worth their weight:

```julia
set_aoi!(cam; x = 0, y = 0, width = 640, height = 480)
reset_aoi!(cam)                                       # back to sensor max

set_trigger!(cam; selector  = :FrameStart,
                  mode      = :On,
                  source    = :Software,
                  activation = :RisingEdge)
disable_trigger!(cam)

set_exposure!(cam, 5000.0)         # µs; falls back to ExposureTimeRaw on legacy GigE
set_gain!(cam, 6.0)                # dB; falls back to GainRaw on legacy GigE
```

Each helper applies the writes in the order the SFNC spec mandates
(e.g. `Width`/`Height` before `OffsetX`/`OffsetY`; `TriggerSelector` →
`TriggerMode` → `TriggerSource` → `TriggerActivation`).

## Saving and restoring user settings

Features tagged `<Streamable>true</Streamable>` in the camera XML can
be snapshotted as XML key-value pairs and restored later:

```julia
using GenICam.GenApi

open("camsetup.xml", "w") do io
    save_settings(io, cam.nodemap, cam.port, cam.api)
end

# later, on this camera or another of the same model:
open("camsetup.xml") do io
    load_settings(io, cam.nodemap, cam.port, cam.api)
end
```

Selectors are written first so dependent features land on the right
channel. Features that fail to read (because of pIsAvailable etc.) are
silently skipped; on restore, write failures are also skipped — a
single bad feature doesn't lose the whole file.

## Direct nodemap access

For introspection or tooling, the parsed nodemap is directly accessible:

```julia
nm = cam.nodemap
nm["Width"]                # IntegerNode
nm["WidthReg"]             # IntRegNode (the backing register)
nm["WidthReg"].address     # 0x00010000 (literal contribution)
nm["WidthReg"].address_spec.terms     # full address composition

# All `IntSwissKnife` nodes:
filter(p -> p.second isa GenApi.IntSwissKnifeNode, collect(nm.nodes))
```

The structs are documented in **[API reference](api.md)**.

## Computed and converted features

Features whose value is derived from a formula (`SwissKnife`,
`IntSwissKnife`, `Converter`, `IntConverter`) are read and written
through the same `cam.X = value` interface; the formula evaluation is
transparent. The expression language has its own page covering operator
precedence, built-in functions, the `FROM` / `TO` convention for
converters, and the vendor-quirk handling — see
[The SwissKnife formula language](swissknife.md).
