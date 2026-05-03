# =============================================================================
# examples/streaming_perf_check.jl
#
# Headless streaming-rate stability check.
#
# Purpose
# -------
# Reproduces the producer side of the GenICamViewer.jl pipeline with **zero
# UI / Qt / QML / image-display code**, so observed pauses can be attributed
# to one of:
#
#   - the GenTL producer DLL (.cti) talking to the camera over USB / GigE;
#   - the GenICam.jl streaming task; or
#   - the host process itself (Julia threading, GC, OS scheduler).
#
# The script:
#
#   1. Loads every `.cti` producer it finds under `GENICAM_GENTL64_PATH`.
#   2. Picks the first camera reported by `list_cameras` across all producers.
#   3. Sets ExposureAuto=Off, ExposureTime=5 ms (so exposure isn't the cap),
#      disables AcquisitionFrameRateEnable / mvAcquisitionFrameRateEnable,
#      sets TriggerMode=Off — i.e. free-running at the sensor's max rate.
#   4. Calls `start_stream` with a `BufferPool` (allocation-free decode hot path).
#   5. Pulls frames from `sh.channel` for `--seconds` seconds (default 60),
#      logging a per-100-frame window summary:
#
#        iter=N grabbed=G dropped=D fps=F max_take=Tms max_pre=Pms max_decode=Dms
#
#      where:
#        max_take  : longest single `take!(sh.channel)` wait. The healthy value
#                    at 9 fps is ≈ 110 ms. Multi-second values mean the
#                    **producer task didn't push for that long** — and since
#                    this script does no Qt/QImage/decode work on the consumer
#                    side, that's purely the GenICam → GenTL DLL side stalling.
#        max_pre   : longest gap between consumer-loop iterations *outside*
#                    take!. Should be sub-ms — if not, the OS/Julia scheduler
#                    starved the consumer.
#        max_decode: not measured here (no decode on consumer side).
#
# Usage
# -----
#   julia --project=. --threads=auto examples/streaming_perf_check.jl
#   julia --project=. --threads=auto examples/streaming_perf_check.jl --seconds 30
#
# Compare the output to the same metrics produced by GenICamViewer.jl's
# instrumented `_stream_loop`. If this script ALSO shows multi-second
# `max_take` pauses, the cause is below Julia/Qt entirely (DLL, USB stack,
# camera firmware). If pauses appear only in the full viewer, the cause is
# something the viewer process introduces (GUI thread, Qt rendering, etc.).
#
# This file is meant to live in the repo as both a regression check and a
# debugging template.
# =============================================================================

using GenICam
using GenICam: GenTL, DecodedFrame, BufferPool

const SEPARATOR = "─" ^ 70

# ── Argument parsing ─────────────────────────────────────────────────────────

function parse_args(argv::Vector{String})
    seconds = 60.0
    i = 1
    while i <= length(argv)
        a = argv[i]
        if a == "--seconds"
            i += 1
            seconds = parse(Float64, argv[i])
        elseif a == "--help" || a == "-h"
            println("Usage: julia --project=. --threads=auto examples/streaming_perf_check.jl [--seconds N]")
            exit(0)
        else
            @warn "unknown argument" arg = a
        end
        i += 1
    end
    return seconds
end

# ── Producer / camera discovery ──────────────────────────────────────────────

function find_cti_files()::Vector{String}
    sep = Sys.iswindows() ? ';' : ':'
    dirs = String[]
    for var in ("GENICAM_GENTL64_PATH", "GENICAM_GENTL32_PATH")
        val = get(ENV, var, "")
        isempty(val) && continue
        append!(dirs, split(val, sep))
    end
    out = String[]
    for d in unique(dirs)
        isdir(d) || continue
        for f in readdir(d; join = true)
            endswith(lowercase(f), ".cti") && push!(out, f)
        end
    end
    return unique(out)
end

function load_all_producers()
    paths = find_cti_files()
    isempty(paths) && error("No .cti files found — set GENICAM_GENTL64_PATH")
    producers = Any[]
    for p in paths
        try
            api = GenTL.load_producer(p)
            push!(producers, GenTL.Producer(api))
            @info "loaded producer" path = p
        catch e
            @warn "failed to load producer" path = p exception = e
        end
    end
    isempty(producers) && error("No producers loaded successfully")
    return producers
end

function find_first_camera(producers)
    for p in producers
        ifaces = GenTL.list_interfaces(p; refresh = true, timeout_ms = 3000)
        for iface_info in ifaces
            iface = nothing
            try
                iface = GenTL.open_interface(p, iface_info)
            catch
                continue
            end
            try
                devs = GenTL.list_devices(iface; refresh = true, timeout_ms = 1500)
                if !isempty(devs)
                    return (producer = p, interface = iface_info, device = devs[1])
                end
            finally
                try; close(iface); catch; end
            end
        end
    end
    error("No cameras found across $(length(producers)) producer(s)")
end

# ── Camera config (mirrors GenICamViewer.jl jl_connect) ──────────────────────

function configure_camera!(cam)
    # Free-running, fixed short exposure so the camera can run at sensor max.
    if haskey(cam.nodemap, "TriggerSelector") && haskey(cam.nodemap, "TriggerMode")
        try
            set_feature!(cam, :TriggerSelector, "FrameStart")
            set_feature!(cam, :TriggerMode, "Off")
        catch
        end
    end
    if haskey(cam.nodemap, "ExposureAuto") && haskey(cam.nodemap, "ExposureTime")
        try
            set_feature!(cam, :ExposureAuto, "Off")
            set_feature!(cam, :ExposureTime, 5000.0)
        catch
        end
    end
    for name in (:AcquisitionFrameRateEnable, :mvAcquisitionFrameRateEnable)
        haskey(cam.nodemap, String(name)) || continue
        try; set_feature!(cam, name, false); catch; end
    end
    function _read(sym)
        haskey(cam.nodemap, String(sym)) || return "(absent)"
        try; return string(get_feature(cam, sym)); catch e; return "(err: $(sprint(showerror, e)))"; end
    end
    @info "camera state" *
          " ExposureTime=$(_read(:ExposureTime))" *
          " mvResultingFrameRate=$(_read(:mvResultingFrameRate))" *
          " AcquisitionFrameRateEnable=$(_read(:AcquisitionFrameRateEnable))" *
          " mvAcquisitionFrameRateEnable=$(_read(:mvAcquisitionFrameRateEnable))" *
          " TriggerMode=$(_read(:TriggerMode))"
end

# ── Streaming consumer loop ──────────────────────────────────────────────────

function stream_for(seconds::Float64, cam)
    @info "stream_for: opening pool + start_stream" seconds threads = Threads.nthreads()
    pool = BufferPool(10)
    sh = start_stream(cam; num_buffers = 10, decode = true,
                       channel_size = 4, policy = DROP_OLDEST,
                       buffer_pool = pool)

    deadline_ns = time_ns() + UInt64(round(seconds * 1e9))
    iter        = 0
    last_end_ns = UInt64(0)
    max_take_ns = UInt64(0)
    max_pre_ns  = UInt64(0)
    last_window_ns = time_ns()
    window_iter_start = 0

    println(SEPARATOR)
    println("streaming for $seconds seconds — Ctrl-C to abort")
    println(SEPARATOR)

    try
        while time_ns() < deadline_ns
            iter_start = time_ns()
            if last_end_ns != 0
                pre_ns = iter_start - last_end_ns
                pre_ns > max_pre_ns && (max_pre_ns = pre_ns)
            end

            local frame
            try
                frame = take!(sh.channel)
            catch
                # channel closed
                break
            end
            take_end = time_ns()
            take_ns  = take_end - iter_start
            take_ns > max_take_ns && (max_take_ns = take_ns)

            frame isa DecodedFrame || continue
            iter += 1

            if iter == 1 || iter % 100 == 0
                window_wall_ns = take_end - last_window_ns
                window_iters   = iter - window_iter_start
                fps = window_iters / (window_wall_ns / 1e9)
                @info "stream_for window" iter grabbed = frames_grabbed(cam) dropped = frames_dropped(cam) fps = round(fps, digits = 2) max_take_ms = round(max_take_ns / 1e6, digits = 1) max_pre_ms = round(max_pre_ns / 1e6, digits = 2)
                max_take_ns = UInt64(0)
                max_pre_ns  = UInt64(0)
                last_window_ns = take_end
                window_iter_start = iter
            end

            last_end_ns = time_ns()
        end
    finally
        try; stop_stream(cam); catch e; @warn "stop_stream" exception = e; end
    end
    return iter, frames_grabbed(cam), frames_dropped(cam)
end

# ── Main ─────────────────────────────────────────────────────────────────────

function main(argv::Vector{String})
    @info "GenICam streaming_perf_check" julia = string(VERSION) threads = Threads.nthreads()
    seconds = parse_args(argv)

    producers = load_all_producers()
    pick = find_first_camera(producers)
    @info "selected camera" vendor = pick.device.vendor model = pick.device.model serial = pick.device.serial tl_type = pick.interface.tl_type

    cam = open_camera(pick.producer, pick.interface, pick.device)
    try
        configure_camera!(cam)

        w = try Int(get_feature(cam, :Width));  catch; 0; end
        h = try Int(get_feature(cam, :Height)); catch; 0; end
        fmt = try string(get_feature(cam, :PixelFormat)); catch; ""; end
        @info "camera reports" width = w height = h format = fmt

        n_iter, total_grabbed, total_dropped = stream_for(seconds, cam)

        println(SEPARATOR)
        @info "session summary" iterations = n_iter total_grabbed = total_grabbed total_dropped = total_dropped
        println(SEPARATOR)
    finally
        try; close(cam); catch e; @warn "close(cam)" exception = e; end
    end

    # Close every producer so .cti DLLs unload cleanly before Julia GC
    # tears down (otherwise finalizers can hang inside the producer DLL).
    for p in producers
        try; close(p); catch; end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
    # Match the viewer's TerminateProcess pattern on Windows so DLL detach
    # hangs (e.g. mvIA's QDxgiVSyncService) don't strand the process.
    if Sys.iswindows()
        proc = ccall((:GetCurrentProcess, "kernel32"), Ptr{Cvoid}, ())
        ccall((:TerminateProcess, "kernel32"), Bool, (Ptr{Cvoid}, UInt32), proc, 0)
    else
        ccall(:_exit, Cvoid, (Cint,), 0)
    end
end
