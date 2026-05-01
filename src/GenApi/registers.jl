"""
Register-level codec and address-resolution machinery.

Two pieces:

1. **Byte codec** — `_decode_int` / `_encode_int` round-trip integer values
   through a producer port's raw byte buffer, honouring endianess and
   signedness.

2. **Address composition** — `AddressTerm` / `AddressSpec` express the GenApi
   model where a register's effective address is a *sum* of contributions:
     * `<Address>0x1000</Address>` — a literal term
     * `<pAddress>BaseReg</pAddress>` — runtime value of a referenced node
     * `<pIndex Offset="N">SelectReg</pIndex>` — `value(SelectReg) * N`

   `_resolve_address` works against a callback so it stays decoupled
   from the rest of the GenApi access layer and is independently
   testable.
"""

# ---------------------------------------------------------------------------
# Byte codec
# ---------------------------------------------------------------------------

"""
    _decode_int(bytes, endianess, sign) -> Int64

Decode up to 8 bytes into a signed 64-bit integer. Wider registers (which
GenApi itself doesn't define for IntReg) raise. Sign-extension is applied
when `sign === SIGNED` and the register is shorter than 64 bits.
"""
function _decode_int(bytes::AbstractVector{UInt8}, endianess::Endianess,
                      sign::Signedness)
    n = length(bytes)
    n == 0 && return Int64(0)
    n > 8 && throw(ArgumentError("register too wide: $n bytes"))
    raw = UInt64(0)
    if endianess === LITTLE_ENDIAN
        @inbounds for i in n:-1:1
            raw = (raw << 8) | UInt64(bytes[i])
        end
    else
        @inbounds for i in 1:n
            raw = (raw << 8) | UInt64(bytes[i])
        end
    end
    if sign === SIGNED && n < 8
        sign_bit = UInt64(1) << (n * 8 - 1)
        mask = (UInt64(1) << (n * 8)) - UInt64(1)
        if (raw & sign_bit) != 0
            raw |= ~mask
        end
    end
    return reinterpret(Int64, raw)
end

"""
    _encode_int(value, length_bytes, endianess, sign) -> Vector{UInt8}

Encode a signed 64-bit integer into `length_bytes` of byte data. Truncates
silently when `value` doesn't fit — that's intentional, GenApi register
writes are by spec masked to the register width.
"""
function _encode_int(value::Integer, n::Integer, endianess::Endianess,
                      ::Signedness)
    raw = reinterpret(UInt64, Int64(value))
    bytes = Vector{UInt8}(undef, n)
    if endianess === LITTLE_ENDIAN
        @inbounds for i in 1:n
            bytes[i] = UInt8(raw & 0xFF)
            raw >>= 8
        end
    else
        @inbounds for i in n:-1:1
            bytes[i] = UInt8(raw & 0xFF)
            raw >>= 8
        end
    end
    return bytes
end

# ---------------------------------------------------------------------------
# Address composition (used by IntReg / FloatReg / StringReg / Register / ...)
# ---------------------------------------------------------------------------

"""
    AddressTerm

One contribution to a register's effective address.

  * `kind === :literal`  — `literal` is the byte address.
  * `kind === :pnode`    — read `ref` (an IInteger node) and add its value.
  * `kind === :pindex`   — read `ref`'s value, multiply by `offset`, then add.
"""
struct AddressTerm
    kind::Symbol
    literal::UInt64
    ref::String
    offset::Int64
end

AddressTerm(literal::Integer) =
    AddressTerm(:literal, UInt64(literal), "", Int64(0))

AddressTerm(ref::AbstractString) =
    AddressTerm(:pnode, UInt64(0), String(ref), Int64(0))

AddressTerm(ref::AbstractString, offset::Integer) =
    AddressTerm(:pindex, UInt64(0), String(ref), Int64(offset))

"""
    AddressSpec(terms)

The full address-composition spec for one register: a list of contributions
that sum at access time. The most common case is a single `:literal` term;
dynamic register banks add `:pnode` and/or `:pindex` siblings.

`address_terms[1]` for a bare-`<Address>` register is exactly the literal,
so the legacy `register.address::UInt64` field can shadow this for backward
compatibility.
"""
struct AddressSpec
    terms::Vector{AddressTerm}
end

AddressSpec(literal::Integer) = AddressSpec([AddressTerm(literal)])

"""
    _resolve_address(spec, evaluate_ref) -> UInt64

Sum all contributions to produce the effective register address.

`evaluate_ref` is a callback `(name::String) -> Integer` that returns the
current value of a referenced IInteger node — it stays a callback so this
function is testable in isolation (Etappe 1) without needing a full
`Nodemap` + `ProducerAPI` chain. Etappe 2 supplies the real callback.
"""
function _resolve_address(spec::AddressSpec, evaluate_ref::Function)
    addr = UInt64(0)
    @inbounds for t in spec.terms
        if t.kind === :literal
            addr += t.literal
        elseif t.kind === :pnode
            addr += UInt64(evaluate_ref(t.ref))
        elseif t.kind === :pindex
            addr += UInt64(evaluate_ref(t.ref)) * UInt64(t.offset)
        else
            throw(ArgumentError("unknown AddressTerm kind: $(t.kind)"))
        end
    end
    return addr
end
