"""
GenApi node types — full GenApi 1.1 schema.

This file defines the abstract type hierarchy plus every concrete node
struct (Integer / Float / Boolean / String / Enumeration / Command, six
register flavours, four formula-driven types, plus Category and
StructEntry). Common metadata lives in a `meta::NodeMetadata` field;
register-bearing nodes additionally carry an `address_spec::AddressSpec`
that captures the full sum-of-terms address composition while keeping a
plain `address::UInt64` for the literal contribution.

Hierarchy:

    Node
      ├── ValueNode             — produces a value (Integer/Float/Bool/String/Enum/Cmd)
      │     └── FormulaNode     — SwissKnife / IntSwissKnife / Converter / IntConverter
      ├── RegisterNode          — IntReg / FloatReg / StringReg / MaskedIntReg / Register / StructReg
      └── StructuralNode        — Category / EnumEntry / StructEntry
"""

# ---------------------------------------------------------------------------
# Enums specific to types/access (Endianess/Signedness/AccessMode are declared
# in GenApi.jl so they're visible to registers.jl too)
# ---------------------------------------------------------------------------

@enum Visibility VIS_BEGINNER = 0 VIS_EXPERT = 1 VIS_GURU = 2 VIS_INVISIBLE = 3
@enum CacheMode NO_CACHE WRITE_THROUGH WRITE_AROUND CACHE_DEFAULT

# ---------------------------------------------------------------------------
# Abstract type hierarchy
# ---------------------------------------------------------------------------

abstract type Node end
abstract type ValueNode <: Node end
abstract type FormulaNode <: ValueNode end
abstract type RegisterNode <: Node end
abstract type StructuralNode <: Node end

# ---------------------------------------------------------------------------
# Cache slot
#
# One mutable cell per cacheable node. For nodes with no `<pSelected>` we
# store a single `(has_value, value)` pair; for selector-dependent nodes
# `selector_cache` keys on the current selector tuple so flipping the
# selector switches to a different value.
# ---------------------------------------------------------------------------

mutable struct CacheSlot
    has_value::Bool
    value::Any
    selector_cache::Union{Nothing,Dict{Tuple,Any}}
end

CacheSlot() = CacheSlot(false, nothing, nothing)

@inline cache_clear!(c::CacheSlot) = begin
    c.has_value = false
    c.value = nothing
    c.selector_cache === nothing || empty!(c.selector_cache)
    c
end

# ---------------------------------------------------------------------------
# Per-node metadata (shared across all node types)
# ---------------------------------------------------------------------------

"""
    NodeMetadata

GenApi attributes that every node carries: visibility, cache policy,
streamable flag, invalidator/selector reverse maps, predicate-node names
(`<pIsAvailable>` etc.), and the run-time cache slot.

Reference fields hold *names* until parser Pass 2 binds them to actual
`Node` references — at which point the `_*_node` companion field gets
filled. The name field stays so error messages can be produced even when
binding partially failed.
"""
mutable struct NodeMetadata
    display_name::String
    tooltip::String
    description::String
    visibility::Visibility
    cacheable::CacheMode
    streamable::Bool
    imposed_access::Union{Nothing,AccessMode}

    # Forward references resolved during Pass 2.
    invalidator_names::Vector{String}      # <pInvalidator>X</pInvalidator>: write to X invalidates me
    selected_names::Vector{String}         # <pSelected>X</pSelected>: write to me invalidates X
    invalidates::Vector{Node}              # reverse map: caches to clear when *I* am written

    is_implemented_name::String
    is_available_name::String
    is_locked_name::String
    is_implemented_node::Union{Nothing,Node}
    is_available_node::Union{Nothing,Node}
    is_locked_node::Union{Nothing,Node}

    cache::CacheSlot
    chunk_id::UInt64                       # 0 = not a chunk feature
end

NodeMetadata() = NodeMetadata(
    "", "", "",
    VIS_BEGINNER, CACHE_DEFAULT, false, nothing,
    String[], String[], Node[],
    "", "", "",
    nothing, nothing, nothing,
    CacheSlot(),
    UInt64(0),
)

# ---------------------------------------------------------------------------
# Address-spec helper — re-exported for terseness inside concrete types
# ---------------------------------------------------------------------------
#
# `AddressSpec` and `AddressTerm` already live in `registers.jl`, included
# before this file. Each register-bearing node embeds an `AddressSpec` in
# `address_spec` and additionally caches the literal-only `address::UInt64`
# as a plain `UInt64` for the common literal-only case.

# ---------------------------------------------------------------------------
# Concrete value-bearing nodes
# ---------------------------------------------------------------------------

"""
    IntegerNode

`<Integer>` GenApi feature. Either backed by a register (`pvalue` names a
register-like node) or a constant literal (`has_literal` is true and
`value` holds it).
"""
mutable struct IntegerNode <: ValueNode
    name::String
    pvalue::String
    value::Int64
    has_literal::Bool
    minimum::Union{Nothing,Int64}
    maximum::Union{Nothing,Int64}
    increment::Union{Nothing,Int64}
    representation::Symbol           # :Linear, :Logarithmic, :PureNumber, :HexNumber, :IPV4Address, :MACAddress, :Boolean
    unit::String
    pvalue_node::Union{Nothing,Node} # filled in Pass 2
    pmin_name::String
    pmax_name::String
    pinc_name::String
    pmin_node::Union{Nothing,Node}
    pmax_node::Union{Nothing,Node}
    pinc_node::Union{Nothing,Node}
    meta::NodeMetadata
end

"""
    FloatNode

`<Float>` GenApi feature. Same structure as `IntegerNode` but in
`Float64` (with optional unit / display precision).
"""
mutable struct FloatNode <: ValueNode
    name::String
    pvalue::String
    value::Float64
    has_literal::Bool
    minimum::Union{Nothing,Float64}
    maximum::Union{Nothing,Float64}
    increment::Union{Nothing,Float64}
    representation::Symbol
    unit::String
    display_precision::Int
    pvalue_node::Union{Nothing,Node}
    pmin_name::String
    pmax_name::String
    pinc_name::String
    pmin_node::Union{Nothing,Node}
    pmax_node::Union{Nothing,Node}
    pinc_node::Union{Nothing,Node}
    meta::NodeMetadata
end

"""
    BooleanNode

`<Boolean>` GenApi feature. The on/off bit lives in `pvalue`'s register;
`on_value` and `off_value` are the integer encodings (defaults 1/0).
"""
mutable struct BooleanNode <: ValueNode
    name::String
    pvalue::String
    on_value::Int64
    off_value::Int64
    pvalue_node::Union{Nothing,Node}
    meta::NodeMetadata
end

"""
    StringNode

`<String>` GenApi feature. `pvalue` resolves to a `StringReg` (or any
register-typed node). When `has_literal` is true the value is fixed.
"""
mutable struct StringNode <: ValueNode
    name::String
    pvalue::String
    value::String
    has_literal::Bool
    pvalue_node::Union{Nothing,Node}
    meta::NodeMetadata
end

"""
    EnumEntryNode

A child of an `EnumerationNode`. Names a possible value of the parent
enum and provides the integer encoding.
"""
mutable struct EnumEntryNode <: StructuralNode
    name::String
    value::Int64
    is_implemented_name::String
    is_available_name::String
    is_implemented_node::Union{Nothing,Node}
    is_available_node::Union{Nothing,Node}
    meta::NodeMetadata
end

EnumEntryNode(name::AbstractString, value::Integer) =
    EnumEntryNode(String(name), Int64(value), "", "", nothing, nothing, NodeMetadata())

"""
    EnumerationNode

`<Enumeration>` GenApi feature: a register-backed integer with named
entries. Reading returns the matching `EnumEntry` name; writing accepts
either an `EnumEntry` name (`String`/`Symbol`) or its integer encoding.
"""
mutable struct EnumerationNode <: ValueNode
    name::String
    pvalue::String
    entries::Vector{EnumEntryNode}
    pvalue_node::Union{Nothing,Node}
    meta::NodeMetadata
end

"""
    CommandNode

`<Command>` GenApi feature: writing `command_value` to `pvalue`'s register
triggers the action. Some cameras use `<pCommandValue>` (computed value
from another node) — that's encoded as `command_value_name` instead.
"""
mutable struct CommandNode <: ValueNode
    name::String
    pvalue::String
    command_value::Int64
    command_value_name::String   # for <pCommandValue> indirection
    pvalue_node::Union{Nothing,Node}
    command_value_node::Union{Nothing,Node}
    meta::NodeMetadata
end

# ---------------------------------------------------------------------------
# Formula-driven value nodes
# ---------------------------------------------------------------------------

"""
    SwissKnifeNode / IntSwissKnifeNode

Computed value: evaluates `<Formula>` (Float64 or Int64 respectively) with
`<pVariable>` bindings. The compiled AST lives in `formula_ast`; raw text
is kept in `formula_src` for diagnostics.
"""
mutable struct SwissKnifeNode <: FormulaNode
    name::String
    formula_src::String
    formula_ast::Union{Nothing,FormulaAST}
    variables::Vector{Pair{Symbol,String}}        # (var name, target node name)
    variable_nodes::Vector{Pair{Symbol,Node}}     # filled in Pass 2
    constants::Dict{Symbol,Float64}               # <Constant> children
    meta::NodeMetadata
end

mutable struct IntSwissKnifeNode <: FormulaNode
    name::String
    formula_src::String
    formula_ast::Union{Nothing,FormulaAST}
    variables::Vector{Pair{Symbol,String}}
    variable_nodes::Vector{Pair{Symbol,Node}}
    constants::Dict{Symbol,Int64}
    meta::NodeMetadata
end

"""
    ConverterNode / IntConverterNode

Bidirectional formula bridge over a backing register-typed `pvalue` node:
  * read  : `eval_float(formula_from, FROM = read(pvalue))`
  * write : `write(pvalue, eval_float(formula_to, TO = value))`

`Converter` operates on Float64; `IntConverter` on Int64.
"""
mutable struct ConverterNode <: FormulaNode
    name::String
    pvalue::String
    formula_to_src::String
    formula_from_src::String
    formula_to_ast::Union{Nothing,FormulaAST}
    formula_from_ast::Union{Nothing,FormulaAST}
    variables::Vector{Pair{Symbol,String}}
    variable_nodes::Vector{Pair{Symbol,Node}}
    constants::Dict{Symbol,Float64}
    is_linear::Bool
    representation::Symbol
    unit::String
    pvalue_node::Union{Nothing,Node}
    meta::NodeMetadata
end

mutable struct IntConverterNode <: FormulaNode
    name::String
    pvalue::String
    formula_to_src::String
    formula_from_src::String
    formula_to_ast::Union{Nothing,FormulaAST}
    formula_from_ast::Union{Nothing,FormulaAST}
    variables::Vector{Pair{Symbol,String}}
    variable_nodes::Vector{Pair{Symbol,Node}}
    constants::Dict{Symbol,Int64}
    is_linear::Bool
    representation::Symbol
    unit::String
    pvalue_node::Union{Nothing,Node}
    meta::NodeMetadata
end

# ---------------------------------------------------------------------------
# Register nodes
# ---------------------------------------------------------------------------

"""
    IntRegNode

`<IntReg>` — the bread-and-butter register holding a signed/unsigned integer.

  * `address::UInt64`   — the literal `<Address>` contribution. If
                          `<pAddress>` / `<pIndex>` siblings exist, the
                          *full* effective address is computed at access
                          time from `address_spec`.
  * `address_spec`      — sum-of-terms representation; for a bare-`<Address>`
                          register this contains a single `:literal` term
                          numerically equal to `address`.
"""
mutable struct IntRegNode <: RegisterNode
    name::String
    address::UInt64
    length::Int
    sign::Signedness
    endianess::Endianess
    access::AccessMode
    port::String
    address_spec::AddressSpec
    representation::Symbol
    meta::NodeMetadata
end

"""
    FloatRegNode

`<FloatReg>` — IEEE 754 register (4 or 8 bytes).
"""
mutable struct FloatRegNode <: RegisterNode
    name::String
    address::UInt64
    length::Int
    endianess::Endianess
    access::AccessMode
    port::String
    address_spec::AddressSpec
    meta::NodeMetadata
end

"""
    StringRegNode

`<StringReg>` — fixed-length zero-terminated ASCII / UTF-8 string register.
"""
mutable struct StringRegNode <: RegisterNode
    name::String
    address::UInt64
    length::Int
    access::AccessMode
    port::String
    address_spec::AddressSpec
    meta::NodeMetadata
end

"""
    MaskedIntRegNode

`<MaskedIntReg>` — IntReg with a bit-field selection (`<Bit>` or
`<LSB>`/`<MSB>`).
"""
mutable struct MaskedIntRegNode <: RegisterNode
    name::String
    address::UInt64
    length::Int
    sign::Signedness
    endianess::Endianess
    access::AccessMode
    port::String
    lsb::Int
    msb::Int
    address_spec::AddressSpec
    meta::NodeMetadata
end

"""
    RegisterRawNode

`<Register>` — raw-bytes register. Read/write returns a `Vector{UInt8}`
unchanged; pixel-format / chunk decoding happens upstream.
"""
mutable struct RegisterRawNode <: RegisterNode
    name::String
    address::UInt64
    length::Int
    access::AccessMode
    port::String
    address_spec::AddressSpec
    meta::NodeMetadata
end

"""
    StructEntryNode

A single bit-field entry of a `StructRegNode`. Read/write delegates to
the parent register with the entry's `lsb`/`msb` mask applied.
"""
mutable struct StructEntryNode <: StructuralNode
    name::String
    parent_struct::String     # name of containing StructRegNode
    parent_node::Union{Nothing,Node}
    sign::Signedness
    lsb::Int
    msb::Int
    access::AccessMode
    meta::NodeMetadata
end

"""
    StructRegNode

`<StructReg>` — a register containing multiple `<StructEntry>` bit-fields.
"""
mutable struct StructRegNode <: RegisterNode
    name::String
    address::UInt64
    length::Int
    sign::Signedness
    endianess::Endianess
    access::AccessMode
    port::String
    entries::Vector{StructEntryNode}
    address_spec::AddressSpec
    meta::NodeMetadata
end

# ---------------------------------------------------------------------------
# Structural node
# ---------------------------------------------------------------------------

"""
    CategoryNode

`<Category>` — pure UI organization. `features` lists child node names
in the order the camera vendor wants them displayed.
"""
mutable struct CategoryNode <: StructuralNode
    name::String
    features::Vector{String}                  # child names from <pFeature>
    feature_nodes::Vector{Node}               # filled in Pass 2
    meta::NodeMetadata
end

# ---------------------------------------------------------------------------
# Nodemap
# ---------------------------------------------------------------------------

"""
    Nodemap

The parsed GenApi node graph for one camera. `nodes` is a name→node lookup;
`feature_names` is a flat ordering of feature-grade nodes (everything that
shows up in the Category tree under "Root", deduplicated).
"""
mutable struct Nodemap
    nodes::Dict{String,Node}
    feature_names::Vector{String}
    root_category::String
    invalidator_map::Dict{String,Vector{String}}    # diagnostic; Pass 2 inverts to node.invalidates
end

Nodemap() = Nodemap(Dict{String,Node}(), String[], "Root",
    Dict{String,Vector{String}}())

Base.show(io::IO, nm::Nodemap) =
    print(io, "Nodemap(", length(nm.nodes), " nodes, ",
        length(nm.feature_names), " features)")

Base.haskey(nm::Nodemap, name::AbstractString) = haskey(nm.nodes, String(name))
Base.getindex(nm::Nodemap, name::AbstractString) = nm.nodes[String(name)]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

"""
    name(n::Node) -> String

Every node knows its own name; this accessor lets generic code retrieve
it without dispatching on type.
"""
@inline name(n::Node) = n.name

"""
    metadata(n::Node) -> NodeMetadata

Common-metadata accessor. Every concrete node type stores it in `meta`.
"""
@inline metadata(n::Node) = n.meta

@inline cache_slot(n::Node) = n.meta.cache

"""
    is_register(n) -> Bool

True iff `n` is a `RegisterNode` subtype (i.e. has an address + length).
"""
@inline is_register(n::Node) = n isa RegisterNode

"""
    is_feature(n) -> Bool

True iff `n` is one of the user-facing "feature" node types — the things
that should appear in `propertynames(camera)`. Excludes register and
structural nodes.
"""
@inline is_feature(n::Node) =
    n isa IntegerNode || n isa FloatNode || n isa BooleanNode ||
    n isa StringNode || n isa EnumerationNode || n isa CommandNode ||
    n isa ConverterNode || n isa IntConverterNode ||
    n isa SwissKnifeNode || n isa IntSwissKnifeNode
