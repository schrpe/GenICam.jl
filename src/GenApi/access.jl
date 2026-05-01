"""
GenApi value access — read, write, execute.

The public entry points `get_value`, `set_value!`, `execute!` are thin
wrappers; everything below is dispatch on the concrete `Node` subtype,
with three cross-cutting concerns:

  * **Address indirection**. A register's effective address may be a sum
    of `<Address>` + `<pAddress>` + `<pIndex Offset=N>` contributions;
    `_resolve_address` walks the `AddressSpec` and recursively reads any
    referenced IInteger nodes.

  * **Recursion guard**. SwissKnife / Converter formulas can reference
    other nodes that themselves evaluate formulas. The `visiting::Set`
    that's threaded through `_read_node` catches cycles before they cause
    a stack overflow.

  * **Caching + invalidation**. Each node carries a `CacheSlot`; reads
    fill it when the cacheable mode allows, writes clear it and walk
    `meta.invalidates` to clear downstream caches. `<pSelected>` gets
    folded into the same reverse map at parse time, so writing a selector
    naturally invalidates every node it selects.
"""

# ===========================================================================
# Public entry points
# ===========================================================================

"""
    get_value(nm, name, port, api) -> value

Read a feature node and return its current value. Type depends on the
node's category: `Int64` for Integer/IntConverter/IntSwissKnife,
`Float64` for Float/Converter/SwissKnife, `Bool` for Boolean, `String`
for String / EnumEntry name.
"""
function get_value(nm::Nodemap, name::AbstractString,
                    port::PORT_HANDLE, api::ProducerAPI)
    n = nm[String(name)]
    visiting = Set{String}()
    _check_availability!(n, nm, port, api, visiting)
    return _cached_read(n, nm, port, api, visiting)
end

"""
    set_value!(nm, name, value, port, api)

Write a value to a feature node. Caching is invalidated for this node and
any node that lists it via `<pInvalidator>` or `<pSelected>`.
"""
function set_value!(nm::Nodemap, name::AbstractString, value,
                     port::PORT_HANDLE, api::ProducerAPI)
    n = nm[String(name)]
    visiting = Set{String}()
    _check_availability!(n, nm, port, api, visiting)
    _write_node(n, value, nm, port, api, visiting)
    _invalidate_nodemap_caches!(nm, n)
    return value
end

"""
    execute!(nm, name, port, api)

Trigger a `Command` node by writing its `<CommandValue>` to the backing
register.
"""
function execute!(nm::Nodemap, name::AbstractString,
                   port::PORT_HANDLE, api::ProducerAPI)
    n = nm[String(name)]
    n isa CommandNode || throw(ArgumentError(
        "Node '$(n.name)' is not a Command (got $(typeof(n)))"))
    visiting = Set{String}()
    _check_availability!(n, nm, port, api, visiting)
    _write_node(n, nothing, nm, port, api, visiting)
    _invalidate_nodemap_caches!(nm, n)
    return nothing
end

# ---------------------------------------------------------------------------
# Availability / implementation predicates
#
# A node may declare `<pIsImplemented>X</pIsImplemented>` (the underlying
# hardware feature exists) or `<pIsAvailable>X</pIsAvailable>` (the feature
# is currently usable given the camera's mode). When either predicate
# evaluates to false, *attempting* to read or write the node is a spec
# violation and on real hardware tends to provoke long I/O timeouts on
# absent registers — so we short-circuit with `FeatureNotAvailable`.
# ---------------------------------------------------------------------------

function _check_availability!(n::Node, nm::Nodemap, port, api,
                                visiting::Set{String})
    if !_eval_predicate_true(n.meta.is_implemented_node, nm, port, api, visiting)
        throw(FeatureNotAvailable(n.name,
            "<pIsImplemented> evaluates to false"))
    end
    if !_eval_predicate_true(n.meta.is_available_node, nm, port, api, visiting)
        throw(FeatureNotAvailable(n.name,
            "<pIsAvailable> evaluates to false"))
    end
    return nothing
end

# Returns true when the predicate is missing (no constraint), or evaluates
# to a non-zero / true value. If the predicate eval itself errors we
# *fail open*: don't block the read just because we couldn't introspect
# the predicate.
function _eval_predicate_true(target::Union{Nothing,Node}, nm, port, api, visiting)
    target === nothing && return true
    try
        v = _cached_read(target, nm, port, api, visiting)
        if v isa Bool;     return v
        elseif v isa Integer;  return v != 0
        elseif v isa AbstractFloat; return v != 0.0
        else; return true
        end
    catch
        return true
    end
end

# ===========================================================================
# Cache layer
# ===========================================================================

@inline _cache_active(n::Node) = n.meta.cacheable !== NO_CACHE

function _cached_read(n::Node, nm::Nodemap, port, api, visiting::Set{String})
    slot = n.meta.cache
    if _cache_active(n) && slot.has_value
        return slot.value
    end
    val = _read_node(n, nm, port, api, visiting)
    if _cache_active(n)
        slot.has_value = true
        slot.value = val
    end
    return val
end

function _invalidate_after_write!(n::Node)
    cache_clear!(n.meta.cache)
    for dep in n.meta.invalidates
        cache_clear!(dep.meta.cache)
    end
    return n
end

# Pessimistic but always-correct invalidation: writes are rare relative to
# reads, and tracking which transitive cache slot to clear (when the write
# goes through a Converter that wraps a register that's also referenced by
# a SwissKnife in another category...) is expensive. Wiping every slot is
# O(nodes) and that's a few thousand cheap field assignments.
function _invalidate_nodemap_caches!(nm::Nodemap, written::Node)
    for n in values(nm.nodes)
        cache_clear!(n.meta.cache)
    end
    return written
end

# ===========================================================================
# Recursion guard
# ===========================================================================

"""
    CircularDependency <: Exception

Raised when a chain of GenApi node references (`pValue` / `pAddress` /
`pIndex` / `pVariable` / formula recursion) revisits a node already on
the resolution stack. Carries the full visit chain so the offending
loop is visible.
"""
struct CircularDependency <: Exception
    chain::Vector{String}
end

Base.showerror(io::IO, e::CircularDependency) =
    print(io, "CircularDependency: GenApi node references form a loop: ",
        join(e.chain, " → "))

"""
    FeatureNotAvailable

Raised when a feature's `<pIsAvailable>` / `<pIsImplemented>` predicate
evaluates to false. Distinct from a genuine read failure: this means the
*camera* declares the feature unavailable (e.g. optional hardware is
missing). Callers can `try` / `catch FeatureNotAvailable` to skip such
features without treating them as errors.
"""
struct FeatureNotAvailable <: Exception
    name::String
    reason::String
end

Base.showerror(io::IO, e::FeatureNotAvailable) =
    print(io, "FeatureNotAvailable('", e.name, "'): ", e.reason)

@inline function _enter!(visiting::Set{String}, name::AbstractString)
    if String(name) in visiting
        throw(CircularDependency(vcat(collect(visiting), String(name))))
    end
    push!(visiting, String(name))
end

@inline _leave!(visiting::Set{String}, name::AbstractString) =
    delete!(visiting, String(name))

# ===========================================================================
# Address resolution
# ===========================================================================

function _resolve_register_address(reg::RegisterNode, nm::Nodemap,
                                     port, api, visiting::Set{String})
    return _resolve_address(reg.address_spec, ref_name -> begin
        target = nm.nodes[ref_name]      # KeyError if undefined — that's fine
        _enter!(visiting, ref_name)
        try
            return _cached_read(target, nm, port, api, visiting) :: Integer
        finally
            _leave!(visiting, ref_name)
        end
    end)
end

# ===========================================================================
# Read dispatch — per concrete node type
# ===========================================================================

# ---- Value-bearing nodes (delegate to backing pvalue node) -----------------

function _read_node(n::IntegerNode, nm::Nodemap, port, api, visiting)
    # pValue takes precedence over Value: many real-world XMLs declare
    # both, where Value is a default and pValue is the live source.
    target = n.pvalue_node
    if target === nothing
        n.has_literal && return n.value
        throw(KeyError(
            "IntegerNode '$(n.name)' references undefined node '$(n.pvalue)'"))
    end
    _enter!(visiting, n.pvalue)
    try
        v = _cached_read(target, nm, port, api, visiting)
        return v isa Integer ? Int64(v) : Int64(floor(Float64(v)))
    finally
        _leave!(visiting, n.pvalue)
    end
end

function _read_node(n::FloatNode, nm::Nodemap, port, api, visiting)
    target = n.pvalue_node
    if target === nothing
        n.has_literal && return n.value
        throw(KeyError(
            "FloatNode '$(n.name)' references undefined node '$(n.pvalue)'"))
    end
    _enter!(visiting, n.pvalue)
    try
        v = _cached_read(target, nm, port, api, visiting)
        return Float64(v)
    finally
        _leave!(visiting, n.pvalue)
    end
end

function _read_node(n::BooleanNode, nm::Nodemap, port, api, visiting)
    target = n.pvalue_node
    target === nothing && throw(KeyError(
        "BooleanNode '$(n.name)' references undefined node '$(n.pvalue)'"))
    _enter!(visiting, n.pvalue)
    try
        raw = _cached_read(target, nm, port, api, visiting)
        return raw == n.on_value
    finally
        _leave!(visiting, n.pvalue)
    end
end

function _read_node(n::StringNode, nm::Nodemap, port, api, visiting)
    n.has_literal && return n.value
    target = n.pvalue_node
    target === nothing && throw(KeyError(
        "StringNode '$(n.name)' references undefined node '$(n.pvalue)'"))
    _enter!(visiting, n.pvalue)
    try
        v = _cached_read(target, nm, port, api, visiting)
        return v isa AbstractString ? String(v) : string(v)
    finally
        _leave!(visiting, n.pvalue)
    end
end

function _read_node(n::EnumerationNode, nm::Nodemap, port, api, visiting)
    target = n.pvalue_node
    target === nothing && throw(KeyError(
        "EnumerationNode '$(n.name)' references undefined node '$(n.pvalue)'"))
    _enter!(visiting, n.pvalue)
    raw = try
        _cached_read(target, nm, port, api, visiting)
    finally
        _leave!(visiting, n.pvalue)
    end
    raw_int = raw isa Integer ? Int64(raw) : Int64(floor(Float64(raw)))
    for e in n.entries
        e.value == raw_int && return e.name
    end
    throw(KeyError("Enumeration '$(n.name)' has no entry for raw value $raw_int"))
end

_read_node(n::CommandNode, ::Nodemap, _, _, _) =
    throw(ArgumentError("Command '$(n.name)' has no readable value; use execute!"))

# ---- Register nodes -------------------------------------------------------

function _read_node(n::IntRegNode, nm::Nodemap, port, api, visiting)
    addr = _resolve_register_address(n, nm, port, api, visiting)
    bytes = gc_read_port(api, port, addr, n.length)
    return _decode_int(bytes, n.endianess, n.sign)
end

function _read_node(n::FloatRegNode, nm::Nodemap, port, api, visiting)
    addr = _resolve_register_address(n, nm, port, api, visiting)
    bytes = gc_read_port(api, port, addr, n.length)
    if n.length == 4
        u = UInt32(_decode_int(bytes, n.endianess, UNSIGNED) & 0xFFFFFFFF)
        return Float64(reinterpret(Float32, u))
    elseif n.length == 8
        u = UInt64(_decode_int(bytes, n.endianess, UNSIGNED))
        return reinterpret(Float64, u)
    else
        throw(ArgumentError(
            "FloatReg '$(n.name)' has unsupported length $(n.length)"))
    end
end

function _read_node(n::StringRegNode, nm::Nodemap, port, api, visiting)
    addr = _resolve_register_address(n, nm, port, api, visiting)
    bytes = gc_read_port(api, port, addr, n.length)
    nul = findfirst(==(0x00), bytes)
    end_idx = nul === nothing ? length(bytes) : nul - 1
    return String(bytes[1:end_idx])
end

function _read_node(n::RegisterRawNode, nm::Nodemap, port, api, visiting)
    addr = _resolve_register_address(n, nm, port, api, visiting)
    return gc_read_port(api, port, addr, n.length)
end

function _read_node(n::MaskedIntRegNode, nm::Nodemap, port, api, visiting)
    addr = _resolve_register_address(n, nm, port, api, visiting)
    bytes = gc_read_port(api, port, addr, n.length)
    raw = _decode_int(bytes, n.endianess, UNSIGNED)
    width = n.msb - n.lsb + 1
    mask = width == 64 ? typemax(UInt64) : (UInt64(1) << width) - UInt64(1)
    field = (UInt64(raw) >> n.lsb) & mask
    if n.sign === SIGNED
        sign_bit = UInt64(1) << (width - 1)
        if (field & sign_bit) != 0
            field |= ~mask
        end
        return reinterpret(Int64, field)
    end
    return Int64(field)
end

function _read_node(n::StructRegNode, ::Nodemap, _, _, _)
    throw(ArgumentError("StructReg '$(n.name)' has no scalar value; " *
        "read its individual <StructEntry> fields instead"))
end

# ---- Formula nodes --------------------------------------------------------

function _read_node(n::SwissKnifeNode, nm::Nodemap, port, api, visiting)
    n.formula_ast === nothing && throw(ArgumentError(
        "SwissKnife '$(n.name)' has no compiled formula"))
    ctx = _eval_context(n, nm, port, api, visiting; integer = false)
    return eval_float(n.formula_ast, ctx)
end

function _read_node(n::IntSwissKnifeNode, nm::Nodemap, port, api, visiting)
    n.formula_ast === nothing && throw(ArgumentError(
        "IntSwissKnife '$(n.name)' has no compiled formula"))
    ctx = _eval_context(n, nm, port, api, visiting; integer = true)
    return eval_int(n.formula_ast, ctx)
end

function _read_node(n::ConverterNode, nm::Nodemap, port, api, visiting)
    n.formula_from_ast === nothing && throw(ArgumentError(
        "Converter '$(n.name)' has no compiled FormulaFrom"))
    target = n.pvalue_node
    target === nothing && throw(KeyError(
        "Converter '$(n.name)' references undefined node '$(n.pvalue)'"))
    _enter!(visiting, n.pvalue)
    raw = try
        _cached_read(target, nm, port, api, visiting)
    finally
        _leave!(visiting, n.pvalue)
    end
    ctx = _converter_context(n, raw, nm, port, api, visiting; integer = false)
    return eval_float(n.formula_from_ast, ctx)
end

function _read_node(n::IntConverterNode, nm::Nodemap, port, api, visiting)
    n.formula_from_ast === nothing && throw(ArgumentError(
        "IntConverter '$(n.name)' has no compiled FormulaFrom"))
    target = n.pvalue_node
    target === nothing && throw(KeyError(
        "IntConverter '$(n.name)' references undefined node '$(n.pvalue)'"))
    _enter!(visiting, n.pvalue)
    raw = try
        _cached_read(target, nm, port, api, visiting)
    finally
        _leave!(visiting, n.pvalue)
    end
    ctx = _converter_context(n, raw, nm, port, api, visiting; integer = true)
    return eval_int(n.formula_from_ast, ctx)
end

# ---- StructEntry — masked field of a parent StructReg ---------------------

function _read_node(n::StructEntryNode, nm::Nodemap, port, api, visiting)
    parent = n.parent_node
    parent === nothing && throw(KeyError(
        "StructEntry '$(n.name)' has no parent struct"))
    addr = _resolve_register_address(parent::StructRegNode, nm, port, api, visiting)
    bytes = gc_read_port(api, port, addr, parent.length)
    raw = _decode_int(bytes, parent.endianess, UNSIGNED)
    width = n.msb - n.lsb + 1
    mask = width == 64 ? typemax(UInt64) : (UInt64(1) << width) - UInt64(1)
    field = (UInt64(raw) >> n.lsb) & mask
    if n.sign === SIGNED
        sign_bit = UInt64(1) << (width - 1)
        (field & sign_bit) != 0 && (field |= ~mask)
        return reinterpret(Int64, field)
    end
    return Int64(field)
end

# ---- Default --------------------------------------------------------------

_read_node(n::Node, ::Nodemap, _, _, _) =
    throw(ArgumentError("read not supported for node $(typeof(n)) '$(n.name)'"))

# ===========================================================================
# Write dispatch
# ===========================================================================

# ---- Value-bearing nodes (delegate to backing register) -------------------

function _write_node(n::IntegerNode, value, nm::Nodemap, port, api, visiting)
    target = n.pvalue_node
    if target === nothing
        # Vendor quirk: some XMLs use a literal-only IntegerNode to express
        # "this selector / enum has exactly one valid value". Writing the
        # matching value is a no-op success; writing a different one is
        # legitimately an error.
        n.has_literal && return _check_literal_match!(n, value)
        throw(KeyError(
            "IntegerNode '$(n.name)' references undefined node '$(n.pvalue)'"))
    end
    raw = Int64(value)
    _write_node(target, raw, nm, port, api, visiting)
end

function _write_node(n::FloatNode, value, nm::Nodemap, port, api, visiting)
    target = n.pvalue_node
    if target === nothing
        n.has_literal && return _check_literal_match!(n, value)
        throw(KeyError(
            "FloatNode '$(n.name)' references undefined node '$(n.pvalue)'"))
    end
    _write_node(target, Float64(value), nm, port, api, visiting)
end

@inline function _check_literal_match!(n::IntegerNode, value)
    Int64(value) == n.value && return nothing
    throw(ArgumentError(
        "IntegerNode '$(n.name)' is a literal fixed at $(n.value); " *
        "cannot write $value"))
end

@inline function _check_literal_match!(n::FloatNode, value)
    Float64(value) == n.value && return nothing
    throw(ArgumentError(
        "FloatNode '$(n.name)' is a literal fixed at $(n.value); " *
        "cannot write $value"))
end

function _write_node(n::BooleanNode, value, nm::Nodemap, port, api, visiting)
    target = n.pvalue_node
    target === nothing && throw(KeyError(
        "BooleanNode '$(n.name)' references undefined node '$(n.pvalue)'"))
    truthy = value === true || value === 1 || value == 1
    raw = truthy ? n.on_value : n.off_value
    _write_node(target, raw, nm, port, api, visiting)
end

function _write_node(n::StringNode, value, nm::Nodemap, port, api, visiting)
    n.has_literal && throw(ArgumentError(
        "StringNode '$(n.name)' is a literal; not writable"))
    target = n.pvalue_node
    target === nothing && throw(KeyError(
        "StringNode '$(n.name)' references undefined node '$(n.pvalue)'"))
    _write_node(target, String(value), nm, port, api, visiting)
end

function _write_node(n::EnumerationNode, value, nm::Nodemap, port, api, visiting)
    raw = if value isa Integer
        Int64(value)
    else
        s = String(value)
        idx = findfirst(e -> e.name == s, n.entries)
        idx === nothing && throw(KeyError(
            "Enumeration '$(n.name)' has no entry named '$s'"))
        n.entries[idx].value
    end
    target = n.pvalue_node
    target === nothing && throw(KeyError(
        "EnumerationNode '$(n.name)' references undefined node '$(n.pvalue)'"))
    _write_node(target, raw, nm, port, api, visiting)
end

function _write_node(n::CommandNode, _, nm::Nodemap, port, api, visiting)
    target = n.pvalue_node
    target === nothing && throw(KeyError(
        "CommandNode '$(n.name)' references undefined node '$(n.pvalue)'"))
    cmd_value = if n.command_value_node !== nothing
        v = _read_node(n.command_value_node, nm, port, api, visiting)
        v isa Integer ? Int64(v) : Int64(floor(Float64(v)))
    else
        n.command_value
    end
    _write_node(target, cmd_value, nm, port, api, visiting)
end

# ---- Register nodes -------------------------------------------------------

function _write_node(n::IntRegNode, value, nm::Nodemap, port, api, visiting)
    n.access === ACC_RO && throw(ArgumentError(
        "IntReg '$(n.name)' is read-only"))
    addr = _resolve_register_address(n, nm, port, api, visiting)
    bytes = _encode_int(Int64(value), n.length, n.endianess, n.sign)
    gc_write_port(api, port, addr, bytes)
end

function _write_node(n::FloatRegNode, value, nm::Nodemap, port, api, visiting)
    n.access === ACC_RO && throw(ArgumentError(
        "FloatReg '$(n.name)' is read-only"))
    addr = _resolve_register_address(n, nm, port, api, visiting)
    if n.length == 4
        bits = UInt32(reinterpret(UInt32, Float32(value)))
        bytes = _encode_int(Int64(bits), 4, n.endianess, UNSIGNED)
    elseif n.length == 8
        bits = reinterpret(UInt64, Float64(value))
        bytes = _encode_int(Int64(bits), 8, n.endianess, UNSIGNED)
    else
        throw(ArgumentError(
            "FloatReg '$(n.name)' has unsupported length $(n.length)"))
    end
    gc_write_port(api, port, addr, bytes)
end

function _write_node(n::StringRegNode, value, nm::Nodemap, port, api, visiting)
    n.access === ACC_RO && throw(ArgumentError(
        "StringReg '$(n.name)' is read-only"))
    addr = _resolve_register_address(n, nm, port, api, visiting)
    s = String(value)
    bytes = Vector{UInt8}(undef, n.length)
    fill!(bytes, 0x00)
    src = codeunits(s)
    cp = min(length(src), n.length - 1)             # leave room for NUL
    @inbounds for i in 1:cp
        bytes[i] = src[i]
    end
    gc_write_port(api, port, addr, bytes)
end

function _write_node(n::RegisterRawNode, value::AbstractVector{UInt8},
                      nm::Nodemap, port, api, visiting)
    n.access === ACC_RO && throw(ArgumentError(
        "Register '$(n.name)' is read-only"))
    addr = _resolve_register_address(n, nm, port, api, visiting)
    gc_write_port(api, port, addr, Vector{UInt8}(value))
end

function _write_node(n::MaskedIntRegNode, value, nm::Nodemap, port, api, visiting)
    n.access === ACC_RO && throw(ArgumentError(
        "MaskedIntReg '$(n.name)' is read-only"))
    addr = _resolve_register_address(n, nm, port, api, visiting)
    cur_bytes = gc_read_port(api, port, addr, n.length)
    cur = _decode_int(cur_bytes, n.endianess, UNSIGNED)
    width = n.msb - n.lsb + 1
    mask = width == 64 ? typemax(UInt64) : (UInt64(1) << width) - UInt64(1)
    field = UInt64(Int64(value)) & mask
    cleared = UInt64(cur) & ~(mask << n.lsb)
    new_word = cleared | (field << n.lsb)
    bytes = _encode_int(Int64(new_word), n.length, n.endianess, UNSIGNED)
    gc_write_port(api, port, addr, bytes)
end

# ---- Formula nodes --------------------------------------------------------

function _write_node(n::ConverterNode, value, nm::Nodemap, port, api, visiting)
    n.formula_to_ast === nothing && throw(ArgumentError(
        "Converter '$(n.name)' has no compiled FormulaTo"))
    target = n.pvalue_node
    target === nothing && throw(KeyError(
        "Converter '$(n.name)' references undefined node '$(n.pvalue)'"))
    ctx = _converter_context(n, Float64(value), nm, port, api, visiting;
        integer = false, write = true)
    raw = eval_float(n.formula_to_ast, ctx)
    _write_node(target, raw, nm, port, api, visiting)
end

function _write_node(n::IntConverterNode, value, nm::Nodemap, port, api, visiting)
    n.formula_to_ast === nothing && throw(ArgumentError(
        "IntConverter '$(n.name)' has no compiled FormulaTo"))
    target = n.pvalue_node
    target === nothing && throw(KeyError(
        "IntConverter '$(n.name)' references undefined node '$(n.pvalue)'"))
    ctx = _converter_context(n, Int64(value), nm, port, api, visiting;
        integer = true, write = true)
    raw = eval_int(n.formula_to_ast, ctx)
    _write_node(target, raw, nm, port, api, visiting)
end

_write_node(n::SwissKnifeNode, _, _, _, _, _) =
    throw(ArgumentError("SwissKnife '$(n.name)' is computed; not writable"))

_write_node(n::IntSwissKnifeNode, _, _, _, _, _) =
    throw(ArgumentError("IntSwissKnife '$(n.name)' is computed; not writable"))

# ---- Default --------------------------------------------------------------

_write_node(n::Node, _, _, _, _, _) =
    throw(ArgumentError("write not supported for node $(typeof(n)) '$(n.name)'"))

# ===========================================================================
# Formula evaluation contexts
# ===========================================================================

# Context for plain SwissKnife / IntSwissKnife: variables resolve to the
# named node's current value, evaluated lazily.
function _eval_context(n::Union{SwissKnifeNode,IntSwissKnifeNode},
                        nm::Nodemap, port, api, visiting; integer::Bool)
    constants = if integer
        n.constants  # Dict{Symbol,Int64}
    else
        n.constants  # Dict{Symbol,Float64}
    end
    var_map = Dict{Symbol,Any}()
    for (vname, vnode) in n.variable_nodes
        var_map[vname] = vnode
    end

    lookup = function (name::Symbol)
        haskey(constants, name) && return constants[name]
        if haskey(var_map, name)
            target = var_map[name]
            target_name = target.name
            _enter!(visiting, target_name)
            try
                return _cached_read(target, nm, port, api, visiting)
            finally
                _leave!(visiting, target_name)
            end
        end
        throw(FormulaEvalError(
            "undefined variable '$name' in formula of '$(n.name)'"))
    end
    return EvalContext(lookup, visiting)
end

# Context for Converter / IntConverter: same as above but with the implicit
# input variable (`FROM` for read path, `TO` for write path).
#
# Pragmatic note: the GenApi spec says `<FormulaFrom>` uses `FROM` and
# `<FormulaTo>` uses `TO`, but many camera vendors (notably MATRIX VISION)
# use `TO` in both formula directions. We bind BOTH names to the input on
# every direction so vendor-quirky XMLs work without us having to second-
# guess the spec text.
function _converter_context(n::Union{ConverterNode,IntConverterNode}, input_value,
                              nm::Nodemap, port, api, visiting;
                              integer::Bool, write::Bool = false)
    constants = n.constants
    var_map = Dict{Symbol,Any}()
    for (vname, vnode) in n.variable_nodes
        var_map[vname] = vnode
    end

    lookup = function (name::Symbol)
        (name === :FROM || name === :TO) && return input_value
        haskey(constants, name) && return constants[name]
        if haskey(var_map, name)
            target = var_map[name]
            target_name = target.name
            _enter!(visiting, target_name)
            try
                return _cached_read(target, nm, port, api, visiting)
            finally
                _leave!(visiting, target_name)
            end
        end
        throw(FormulaEvalError(
            "undefined variable '$name' in formula of '$(n.name)'"))
    end
    return EvalContext(lookup, visiting)
end
