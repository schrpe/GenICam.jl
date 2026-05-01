"""
    GenICam.GenApi

Full GenApi node-map. Loads the camera's XML description from the
remote device port, builds a complete node graph (Integer / Float /
Boolean / String / Enumeration / Command / IntReg / FloatReg / StringReg
/ MaskedIntReg / Register / StructReg / SwissKnife / IntSwissKnife /
Converter / IntConverter / Category), and supports register-address
indirection (`<pAddress>` / `<pIndex>`), formula evaluation (full
SwissKnife operator set with `<Constant>`/`<pVariable>` resolution),
caching with `<pInvalidator>` / `<pSelected>` reverse maps, and
`<Streamable>` save/load.
"""
module GenApi

using ..GenTL

# Order matters:
#   1. registers.jl  — Endianess/Signedness/AccessMode enums + codec +
#                       AddressSpec (no Node dependency)
#   2. types.jl      — Node hierarchy + concrete node structs (uses the
#                       enums + AddressSpec)
#   3. formula.jl    — SwissKnife evaluator (uses FormulaAST type defined
#                       inside, but referenced by SwissKnifeNode etc.)
#   4. xml.jl        — port → XML loader (independent)
#   5. parser.jl     — XML → Nodemap
#   6. access.jl     — read_value / write_value / execute! (uses everything)
#   7. streamable.jl — UserSet save/load (uses access.jl)
#
# The forward-reference between SwissKnifeNode (in types.jl) referencing
# `FormulaAST` (in formula.jl) is fine in Julia because mutable struct
# field types only need to be resolvable at construction time, not at the
# struct-definition's parse time — an abstract supertype declared after
# the struct still works as a field type.

# Define FormulaAST as an empty abstract type early so types.jl can reference
# it. The concrete subtypes and parser come from formula.jl below.
abstract type FormulaAST end

# The register-codec / address-spec enums are referenced by registers.jl
# (in function signatures) AND by types.jl (in struct fields), so they
# need to be in scope before either is included. Declared here so the
# include order isn't constrained.
@enum Endianess BIG_ENDIAN LITTLE_ENDIAN
@enum Signedness SIGNED UNSIGNED
@enum AccessMode ACC_RO ACC_WO ACC_RW

include("registers.jl")
include("types.jl")
include("formula.jl")
include("xml.jl")
include("parser.jl")
include("access.jl")
include("streamable.jl")

# ---------------------------------------------------------------------------
# Public exports
# ---------------------------------------------------------------------------

export
    # Enums
    Endianess, BIG_ENDIAN, LITTLE_ENDIAN,
    Signedness, SIGNED, UNSIGNED,
    AccessMode, ACC_RO, ACC_WO, ACC_RW,
    Visibility, VIS_BEGINNER, VIS_EXPERT, VIS_GURU, VIS_INVISIBLE,
    CacheMode, NO_CACHE, WRITE_THROUGH, WRITE_AROUND, CACHE_DEFAULT,
    # Types
    Node, ValueNode, FormulaNode, RegisterNode, StructuralNode,
    NodeMetadata, CacheSlot,
    AddressTerm, AddressSpec,
    IntegerNode, FloatNode, BooleanNode, StringNode,
    EnumEntryNode, EnumerationNode, CommandNode,
    IntRegNode, FloatRegNode, StringRegNode, MaskedIntRegNode,
    RegisterRawNode, StructRegNode, StructEntryNode,
    SwissKnifeNode, IntSwissKnifeNode,
    ConverterNode, IntConverterNode,
    CategoryNode,
    Nodemap,
    # Errors
    FormulaParseError, FormulaEvalError, CircularDependency,
    FeatureNotAvailable,
    # XML loader
    load_xml, NotImplementedYet,
    # Formula language (also used by tests)
    FormulaAST, parse_formula, eval_int, eval_float,
    evaluate_int, evaluate_float, EvalContext,
    # Public API
    parse_nodemap, get_value, set_value!, execute!,
    save_settings, load_settings,
    name, metadata, is_register, is_feature

end # module GenApi
