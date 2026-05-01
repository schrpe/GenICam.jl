# Shared test helpers for pixel-format unit tests.
# Builds a synthetic Frame from raw bytes — no GenTL handle, no producer.

using GenICam.GenTL: Frame

function fakeframe(bytes::Vector{UInt8}, w::Integer, h::Integer,
                    pf::Integer, ns::Integer = 0)
    return Frame(C_NULL, bytes, Csize_t(length(bytes)),
        Csize_t(w), Csize_t(h), UInt64(pf), UInt64(ns), false)
end
