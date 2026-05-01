"""
SFNC convenience helpers.

Every SFNC feature is already reachable as `cam.X` through the GenApi
layer, but the common workflows below are tedious enough — and have
enough order-sensitivity — that wrapping them pays off:

  * `set_aoi!`  — set Width/Height *before* OffsetX/OffsetY (the camera
                  rejects the order otherwise on most sensors), with
                  automatic clamping against `WidthMax`/`HeightMax` when
                  those features are exposed.
  * `set_trigger!` — drive the SFNC trigger-selector chain
                  (TriggerSelector → TriggerMode → TriggerSource →
                  TriggerActivation) in the order the spec mandates.
  * `set_exposure!` / `set_gain!` — prefer the modern Float-typed
                  features (`ExposureTime` µs, `Gain` dB), fall back to
                  the legacy raw integer features (`ExposureTimeRaw`,
                  `GainRaw`) for older GigE Vision cameras.
  * `features` / `categories` / `features_in` — filtered listings of the
                  parsed nodemap, gated by GenApi `<Visibility>`.

These functions don't add new functionality on top of `set_feature!` —
they encode the right *order* and *fallback chain* that a SFNC-compliant
camera expects.
"""

# ---------------------------------------------------------------------------
# AOI
# ---------------------------------------------------------------------------

"""
    set_aoi!(cam; x=0, y=0, width, height)

Configure the active sensor area. Order matters: Width/Height go first
(otherwise OffsetX+Width might exceed the current sensor width and the
camera rejects the write); we then write OffsetX/OffsetY. We zero the
offsets first if the new (width, height) wouldn't fit at the current
offset.

`width`/`height` are clamped against `WidthMax`/`HeightMax` (or the
GenApi node's max) when those features are exposed.
"""
function set_aoi!(cam::Camera; x::Integer = 0, y::Integer = 0,
                   width::Integer, height::Integer)
    has_w = haskey(cam.nodemap, "Width")
    has_h = haskey(cam.nodemap, "Height")
    has_w && has_h || throw(ArgumentError(
        "set_aoi!: camera has no Width/Height features"))

    wmax = _get_max(cam, "Width", "WidthMax")
    hmax = _get_max(cam, "Height", "HeightMax")
    w = Int(min(wmax === nothing ? width : wmax, width))
    h = Int(min(hmax === nothing ? height : hmax, height))

    # Zero offsets first if the new geometry would otherwise overflow the
    # current ones. Catch errors quietly — some cameras don't expose Offset.
    if haskey(cam.nodemap, "OffsetX")
        try; set_feature!(cam, :OffsetX, 0); catch; end
    end
    if haskey(cam.nodemap, "OffsetY")
        try; set_feature!(cam, :OffsetY, 0); catch; end
    end

    set_feature!(cam, :Width, w)
    set_feature!(cam, :Height, h)

    if x != 0 && haskey(cam.nodemap, "OffsetX")
        set_feature!(cam, :OffsetX, Int(x))
    end
    if y != 0 && haskey(cam.nodemap, "OffsetY")
        set_feature!(cam, :OffsetY, Int(y))
    end
    return cam
end

"""
    reset_aoi!(cam)

Set the AOI to the full sensor: Width/Height to their max, OffsetX/Y to 0.
"""
function reset_aoi!(cam::Camera)
    if haskey(cam.nodemap, "OffsetX")
        try; set_feature!(cam, :OffsetX, 0); catch; end
    end
    if haskey(cam.nodemap, "OffsetY")
        try; set_feature!(cam, :OffsetY, 0); catch; end
    end
    wmax = _get_max(cam, "Width", "WidthMax")
    hmax = _get_max(cam, "Height", "HeightMax")
    wmax === nothing || set_feature!(cam, :Width, Int(wmax))
    hmax === nothing || set_feature!(cam, :Height, Int(hmax))
    return cam
end

# Read the maximum value for a feature, preferring a "<Foo>Max" sibling
# feature when the camera exposes one (most do); otherwise consult the
# GenApi `<Max>` field on the node itself.
function _get_max(cam::Camera, name::AbstractString, max_sibling::AbstractString)
    if haskey(cam.nodemap, max_sibling)
        try
            return Int(get_feature(cam, Symbol(max_sibling)))
        catch
        end
    end
    n = cam.nodemap[String(name)]
    if n isa GenApi.IntegerNode && n.maximum !== nothing
        return Int(n.maximum)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Trigger
# ---------------------------------------------------------------------------

"""
    set_trigger!(cam; selector=:FrameStart, mode=:On, source=:Line0,
                       activation=:RisingEdge)

Configure the SFNC trigger chain. Writes happen in the spec'd order:

    TriggerSelector → TriggerMode → (TriggerSource → TriggerActivation if mode == :On)

`source` and `activation` are skipped when `mode == :Off`.
"""
function set_trigger!(cam::Camera;
                       selector::Union{Symbol,AbstractString} = :FrameStart,
                       mode::Union{Symbol,AbstractString} = :On,
                       source::Union{Symbol,AbstractString,Nothing} = :Line0,
                       activation::Union{Symbol,AbstractString,Nothing} = :RisingEdge)
    haskey(cam.nodemap, "TriggerSelector") || throw(ArgumentError(
        "set_trigger!: camera has no TriggerSelector"))

    set_feature!(cam, :TriggerSelector, String(selector))
    set_feature!(cam, :TriggerMode, String(mode))

    if String(mode) == "On"
        if source !== nothing && haskey(cam.nodemap, "TriggerSource")
            set_feature!(cam, :TriggerSource, String(source))
        end
        if activation !== nothing && haskey(cam.nodemap, "TriggerActivation")
            try
                set_feature!(cam, :TriggerActivation, String(activation))
            catch
                # not all sources support every activation; ignore
            end
        end
    end
    return cam
end

"""
    disable_trigger!(cam; selector=:FrameStart)

Equivalent to `set_trigger!(cam; selector=selector, mode=:Off)`.
"""
disable_trigger!(cam::Camera;
                 selector::Union{Symbol,AbstractString} = :FrameStart) =
    set_trigger!(cam; selector = selector, mode = :Off,
        source = nothing, activation = nothing)

# ---------------------------------------------------------------------------
# Exposure / Gain
# ---------------------------------------------------------------------------

"""
    set_exposure!(cam, microseconds::Real; auto=:Off)

Set the exposure time in microseconds. Prefers `ExposureTime` (Float, µs
per SFNC); falls back to `ExposureTimeRaw` (Integer, raw camera ticks)
for legacy GigE Vision cameras that don't expose the modern feature.

`auto` controls `ExposureAuto` if the feature is present (`:Off` /
`:Once` / `:Continuous`).
"""
function set_exposure!(cam::Camera, microseconds::Real;
                        auto::Union{Symbol,AbstractString} = :Off)
    if haskey(cam.nodemap, "ExposureAuto")
        try
            set_feature!(cam, :ExposureAuto, String(auto))
        catch
        end
    end
    # Some cameras use a Mode selector (Timed / TriggerWidth)
    if haskey(cam.nodemap, "ExposureMode")
        try
            set_feature!(cam, :ExposureMode, "Timed")
        catch
        end
    end
    if haskey(cam.nodemap, "ExposureTime")
        set_feature!(cam, :ExposureTime, Float64(microseconds))
    elseif haskey(cam.nodemap, "ExposureTimeAbs")
        set_feature!(cam, :ExposureTimeAbs, Float64(microseconds))
    elseif haskey(cam.nodemap, "ExposureTimeRaw")
        set_feature!(cam, :ExposureTimeRaw, Int(round(microseconds)))
    else
        throw(ArgumentError(
            "set_exposure!: no ExposureTime / ExposureTimeAbs / ExposureTimeRaw " *
            "feature on this camera"))
    end
    return cam
end

"""
    set_gain!(cam, db::Real; auto=:Off)

Set the analog gain in decibels. Prefers `Gain` (Float, dB per SFNC);
falls back to `GainRaw` (Integer, raw register value) for legacy GigE
cameras that don't expose the modern feature.
"""
function set_gain!(cam::Camera, db::Real;
                    auto::Union{Symbol,AbstractString} = :Off)
    if haskey(cam.nodemap, "GainAuto")
        try
            set_feature!(cam, :GainAuto, String(auto))
        catch
        end
    end
    if haskey(cam.nodemap, "Gain")
        set_feature!(cam, :Gain, Float64(db))
    elseif haskey(cam.nodemap, "GainRaw")
        set_feature!(cam, :GainRaw, Int(round(db)))
    else
        throw(ArgumentError(
            "set_gain!: no Gain / GainRaw feature on this camera"))
    end
    return cam
end

# ---------------------------------------------------------------------------
# Feature listing / filtering
# ---------------------------------------------------------------------------

"""
    features(cam; visibility=:Guru, category=nothing) -> Vector{String}

List the camera's user-facing features, optionally filtered.

  * `visibility` is one of `:Beginner`, `:Expert`, `:Guru`, or
    `:Invisible`. Features whose declared `<Visibility>` is *more*
    expert than the requested level are hidden. Default `:Guru` shows
    everything except `:Invisible`.
  * `category` restricts to features under the named GenApi `<Category>`
    branch.
"""
function features(cam::Camera; visibility::Symbol = :Guru,
                   category::Union{Nothing,AbstractString} = nothing)
    threshold = _visibility_level(visibility)
    out = String[]
    src = category === nothing ? cam.nodemap.feature_names :
                                  features_in(cam, category)
    for fname in src
        haskey(cam.nodemap, fname) || continue
        n = cam.nodemap[fname]
        if Int(n.meta.visibility) <= threshold
            push!(out, fname)
        end
    end
    return out
end

"""
    categories(cam) -> Vector{String}

List the names of every `<Category>` node in the parsed nodemap, in
declaration order.
"""
function categories(cam::Camera)
    out = String[]
    for (name, n) in cam.nodemap.nodes
        n isa GenApi.CategoryNode && push!(out, name)
    end
    sort!(out)
    return out
end

"""
    features_in(cam, category::AbstractString) -> Vector{String}

List the feature names directly under `category`, in declaration order.
Recursive: if a sub-element is itself a Category, its features are
inlined into the result.
"""
function features_in(cam::Camera, category::AbstractString)
    haskey(cam.nodemap, String(category)) || throw(KeyError(
        "no Category named '$category'"))
    out = String[]
    seen = Set{String}()
    _walk_category!(out, seen, cam.nodemap, String(category))
    return out
end

function _walk_category!(out::Vector{String}, seen::Set{String},
                          nm::GenApi.Nodemap, name::AbstractString)
    haskey(nm, String(name)) || return
    n = nm[String(name)]
    if n isa GenApi.CategoryNode
        for fname in n.features
            _walk_category!(out, seen, nm, fname)
        end
    else
        n.name in seen && return
        push!(seen, n.name)
        GenApi.is_feature(n) && push!(out, n.name)
    end
    return
end

@inline function _visibility_level(s::Symbol)
    s === :Beginner  && return Int(GenApi.VIS_BEGINNER)
    s === :Expert    && return Int(GenApi.VIS_EXPERT)
    s === :Guru      && return Int(GenApi.VIS_GURU)
    s === :Invisible && return Int(GenApi.VIS_INVISIBLE)
    throw(ArgumentError("unknown visibility level: $s — expected one of " *
        ":Beginner :Expert :Guru :Invisible"))
end
