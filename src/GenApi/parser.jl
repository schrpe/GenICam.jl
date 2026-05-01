"""
GenApi XML → Nodemap parser, three-pass.

Pass 1 walks `<RegisterDescription>`'s children and constructs each node
with reference fields stored as strings. Pass 2 resolves those strings to
actual `Node` instances and builds the invalidator reverse map. Pass 3
compiles each `FormulaNode`'s `<Formula>` text into a cached AST. Pass 4
(cheap) walks the Category tree to populate the ordered `feature_names`
list.

Forward references are pervasive in real camera XMLs (e.g. `Width` before
`WidthReg` is declared) — that's why we can't combine passes. Pass 1
errors that don't match any known tag are silently dropped (vendor
extensions); errors *within* a known tag (malformed Address etc.) raise.
"""

using EzXML

# ===========================================================================
# Public entry
# ===========================================================================

"""
    parse_nodemap(xml::AbstractString) -> Nodemap

Build a complete `Nodemap` from the camera's XML description.
"""
function parse_nodemap(xml::AbstractString)
    doc = EzXML.parsexml(String(xml))
    root_el = EzXML.root(doc)

    nm = Nodemap()

    # ---- Pass 1: shallow construction ----
    for el in EzXML.eachelement(root_el)
        node = _construct_shallow(EzXML.nodename(el), el)
        node === nothing && continue
        nm.nodes[node.name] = node
    end

    # ---- Pass 2: bind references ----
    _resolve_refs!(nm)

    # ---- Pass 3: compile formulas ----
    _compile_formulas!(nm)

    # ---- Pass 4: build feature ordering from Category tree ----
    nm.feature_names = _walk_category_tree(nm)

    return nm
end

# ===========================================================================
# Pass 1 — node construction (per-tag dispatch)
# ===========================================================================

function _construct_shallow(tag::AbstractString, el::EzXML.Node)
    if     tag == "Integer"        return _parse_integer(el)
    elseif tag == "IntReg"         return _parse_intreg(el)
    elseif tag == "Float"          return _parse_float(el)
    elseif tag == "FloatReg"       return _parse_floatreg(el)
    elseif tag == "Boolean"        return _parse_boolean(el)
    elseif tag == "String"         return _parse_string(el)
    elseif tag == "StringReg"      return _parse_stringreg(el)
    elseif tag == "Register"       return _parse_register_raw(el)
    elseif tag == "MaskedIntReg"   return _parse_masked_intreg(el)
    elseif tag == "StructReg"      return _parse_struct_reg(el)
    elseif tag == "Enumeration"    return _parse_enumeration(el)
    elseif tag == "Command"        return _parse_command(el)
    elseif tag == "SwissKnife"     return _parse_swissknife(el; integer = false)
    elseif tag == "IntSwissKnife"  return _parse_swissknife(el; integer = true)
    elseif tag == "Converter"      return _parse_converter(el; integer = false)
    elseif tag == "IntConverter"   return _parse_converter(el; integer = true)
    elseif tag == "Category"       return _parse_category(el)
    end
    return nothing
end

# ===========================================================================
# XML helper utilities
# ===========================================================================

function _attr_name(el::EzXML.Node)
    EzXML.haskey(el, "Name") ? String(el["Name"]) : ""
end

function _children(el::EzXML.Node, tag::AbstractString)
    out = EzXML.Node[]
    for c in EzXML.eachelement(el)
        EzXML.nodename(c) == tag && push!(out, c)
    end
    out
end

function _child_text(el::EzXML.Node, tag::AbstractString, default::AbstractString = "")
    for c in EzXML.eachelement(el)
        EzXML.nodename(c) == tag && return String(strip(EzXML.nodecontent(c)))
    end
    return String(default)
end

function _child_int(el::EzXML.Node, tag::AbstractString,
                    default::Union{Nothing,Int64} = nothing)
    s = _child_text(el, tag)
    isempty(s) && return default
    return _parse_integer_literal(s)
end

function _child_float(el::EzXML.Node, tag::AbstractString,
                       default::Union{Nothing,Float64} = nothing)
    s = _child_text(el, tag)
    isempty(s) && return default
    return parse(Float64, s)
end

function _parse_integer_literal(s::AbstractString)
    t = String(strip(s))
    if startswith(lowercase(t), "0x")
        return Int64(parse(UInt64, t[3:end]; base = 16))
    end
    return parse(Int64, t)
end

function _parse_uint64_literal(s::AbstractString)
    t = String(strip(s))
    if startswith(lowercase(t), "0x")
        return parse(UInt64, t[3:end]; base = 16)
    end
    return parse(UInt64, t)
end

function _parse_access(s::AbstractString)
    t = String(strip(s))
    t == "RO" && return ACC_RO
    t == "WO" && return ACC_WO
    return ACC_RW
end

function _parse_visibility(s::AbstractString)
    t = String(strip(s))
    t == "Beginner"  && return VIS_BEGINNER
    t == "Expert"    && return VIS_EXPERT
    t == "Guru"      && return VIS_GURU
    t == "Invisible" && return VIS_INVISIBLE
    return VIS_BEGINNER
end

function _parse_cacheable(s::AbstractString)
    t = String(strip(s))
    t == "NoCache"      && return NO_CACHE
    t == "WriteThrough" && return WRITE_THROUGH
    t == "WriteAround"  && return WRITE_AROUND
    return CACHE_DEFAULT
end

# ===========================================================================
# Common-metadata extractor
# ===========================================================================

function _extract_metadata!(meta::NodeMetadata, el::EzXML.Node)
    for c in EzXML.eachelement(el)
        tag = EzXML.nodename(c)
        if tag == "DisplayName"
            meta.display_name = String(strip(EzXML.nodecontent(c)))
        elseif tag == "ToolTip"
            meta.tooltip = String(strip(EzXML.nodecontent(c)))
        elseif tag == "Description"
            meta.description = String(strip(EzXML.nodecontent(c)))
        elseif tag == "Visibility"
            meta.visibility = _parse_visibility(EzXML.nodecontent(c))
        elseif tag == "Cacheable"
            meta.cacheable = _parse_cacheable(EzXML.nodecontent(c))
        elseif tag == "Streamable"
            meta.streamable = lowercase(strip(EzXML.nodecontent(c))) == "yes"
        elseif tag == "ImposedAccessMode"
            meta.imposed_access = _parse_access(EzXML.nodecontent(c))
        elseif tag == "pInvalidator"
            push!(meta.invalidator_names, String(strip(EzXML.nodecontent(c))))
        elseif tag == "pSelected"
            push!(meta.selected_names, String(strip(EzXML.nodecontent(c))))
        elseif tag == "pIsImplemented"
            meta.is_implemented_name = String(strip(EzXML.nodecontent(c)))
        elseif tag == "pIsAvailable"
            meta.is_available_name = String(strip(EzXML.nodecontent(c)))
        elseif tag == "pIsLocked"
            meta.is_locked_name = String(strip(EzXML.nodecontent(c)))
        elseif tag == "ChunkID"
            meta.chunk_id = _parse_uint64_literal(EzXML.nodecontent(c))
        end
    end
    return meta
end

# ===========================================================================
# Register-spec extractor (Address / pAddress / pIndex / Length / Sign / ...)
# ===========================================================================

"""
Extract the register-shaped fields (literal address + AddressSpec, length,
sign, endianess, access, port). Some registers are sign-less (Float, String);
caller picks which fields it actually uses.
"""
function _extract_register_spec(el::EzXML.Node)
    literal_addr = UInt64(0)
    have_literal = false
    terms = AddressTerm[]
    length_bytes = 0
    sign = UNSIGNED
    endianess = LITTLE_ENDIAN
    access = ACC_RW
    port = "Device"

    for c in EzXML.eachelement(el)
        tag = EzXML.nodename(c)
        if tag == "Address"
            v = _parse_uint64_literal(EzXML.nodecontent(c))
            push!(terms, AddressTerm(v))
            literal_addr += v
            have_literal = true
        elseif tag == "pAddress"
            push!(terms, AddressTerm(String(strip(EzXML.nodecontent(c)))))
        elseif tag == "pIndex"
            offset = if EzXML.haskey(c, "Offset")
                _parse_integer_literal(c["Offset"])
            elseif EzXML.haskey(c, "pOffset")
                # rare; offset is itself a node reference. We don't resolve
                # this path (would need another indirection at access time);
                # fall back to 1.
                Int64(1)
            else
                Int64(1)
            end
            ref = String(strip(EzXML.nodecontent(c)))
            push!(terms, AddressTerm(ref, offset))
        elseif tag == "Length"
            length_bytes = _parse_integer_literal(EzXML.nodecontent(c))
        elseif tag == "Sign"
            sign = String(strip(EzXML.nodecontent(c))) == "Signed" ? SIGNED : UNSIGNED
        elseif tag == "Endianess"
            endianess = String(strip(EzXML.nodecontent(c))) == "BigEndian" ?
                BIG_ENDIAN : LITTLE_ENDIAN
        elseif tag == "AccessMode"
            access = _parse_access(EzXML.nodecontent(c))
        elseif tag == "pPort"
            port = String(strip(EzXML.nodecontent(c)))
        end
    end

    spec = AddressSpec(isempty(terms) ? [AddressTerm(UInt64(0))] : terms)
    return (literal_addr, spec, length_bytes, sign, endianess, access, port)
end

# ===========================================================================
# Per-tag node constructors
# ===========================================================================

function _parse_integer(el::EzXML.Node)
    name = _attr_name(el)
    isempty(name) && return nothing

    pvalue = ""
    has_literal = false
    value = Int64(0)
    minimum = nothing
    maximum = nothing
    increment = nothing
    representation = :PureNumber
    unit = ""
    pmin = ""; pmax = ""; pinc = ""

    for c in EzXML.eachelement(el)
        tag = EzXML.nodename(c)
        if tag == "pValue"
            pvalue = String(strip(EzXML.nodecontent(c)))
        elseif tag == "Value"
            has_literal = true
            value = _parse_integer_literal(EzXML.nodecontent(c))
        elseif tag == "Min"
            minimum = _parse_integer_literal(EzXML.nodecontent(c))
        elseif tag == "Max"
            maximum = _parse_integer_literal(EzXML.nodecontent(c))
        elseif tag == "Inc"
            increment = _parse_integer_literal(EzXML.nodecontent(c))
        elseif tag == "Representation"
            representation = Symbol(strip(EzXML.nodecontent(c)))
        elseif tag == "Unit"
            unit = String(strip(EzXML.nodecontent(c)))
        elseif tag == "pMin"
            pmin = String(strip(EzXML.nodecontent(c)))
        elseif tag == "pMax"
            pmax = String(strip(EzXML.nodecontent(c)))
        elseif tag == "pInc"
            pinc = String(strip(EzXML.nodecontent(c)))
        end
    end

    isempty(pvalue) && !has_literal && return nothing

    meta = NodeMetadata()
    _extract_metadata!(meta, el)
    return IntegerNode(name, pvalue, value, has_literal, minimum, maximum,
        increment, representation, unit, nothing,
        pmin, pmax, pinc, nothing, nothing, nothing, meta)
end

function _parse_float(el::EzXML.Node)
    name = _attr_name(el)
    isempty(name) && return nothing

    pvalue = ""
    has_literal = false
    value = 0.0
    minimum = nothing
    maximum = nothing
    increment = nothing
    representation = :PureNumber
    unit = ""
    display_precision = 6
    pmin = ""; pmax = ""; pinc = ""

    for c in EzXML.eachelement(el)
        tag = EzXML.nodename(c)
        if tag == "pValue"
            pvalue = String(strip(EzXML.nodecontent(c)))
        elseif tag == "Value"
            has_literal = true
            value = parse(Float64, EzXML.nodecontent(c))
        elseif tag == "Min"
            minimum = parse(Float64, EzXML.nodecontent(c))
        elseif tag == "Max"
            maximum = parse(Float64, EzXML.nodecontent(c))
        elseif tag == "Inc"
            increment = parse(Float64, EzXML.nodecontent(c))
        elseif tag == "Representation"
            representation = Symbol(strip(EzXML.nodecontent(c)))
        elseif tag == "Unit"
            unit = String(strip(EzXML.nodecontent(c)))
        elseif tag == "DisplayPrecision"
            display_precision = parse(Int, EzXML.nodecontent(c))
        elseif tag == "pMin"
            pmin = String(strip(EzXML.nodecontent(c)))
        elseif tag == "pMax"
            pmax = String(strip(EzXML.nodecontent(c)))
        elseif tag == "pInc"
            pinc = String(strip(EzXML.nodecontent(c)))
        end
    end

    isempty(pvalue) && !has_literal && return nothing

    meta = NodeMetadata()
    _extract_metadata!(meta, el)
    return FloatNode(name, pvalue, value, has_literal, minimum, maximum,
        increment, representation, unit, display_precision, nothing,
        pmin, pmax, pinc, nothing, nothing, nothing, meta)
end

function _parse_boolean(el::EzXML.Node)
    name = _attr_name(el)
    isempty(name) && return nothing
    pvalue = _child_text(el, "pValue")
    on_value = _child_int(el, "OnValue", Int64(1))
    off_value = _child_int(el, "OffValue", Int64(0))
    isempty(pvalue) && return nothing

    meta = NodeMetadata()
    _extract_metadata!(meta, el)
    return BooleanNode(name, pvalue, on_value, off_value, nothing, meta)
end

function _parse_string(el::EzXML.Node)
    name = _attr_name(el)
    isempty(name) && return nothing

    pvalue = ""
    has_literal = false
    value = ""

    for c in EzXML.eachelement(el)
        tag = EzXML.nodename(c)
        if tag == "pValue"
            pvalue = String(strip(EzXML.nodecontent(c)))
        elseif tag == "Value"
            has_literal = true
            value = String(strip(EzXML.nodecontent(c)))
        end
    end
    isempty(pvalue) && !has_literal && return nothing

    meta = NodeMetadata()
    _extract_metadata!(meta, el)
    return StringNode(name, pvalue, value, has_literal, nothing, meta)
end

function _parse_intreg(el::EzXML.Node)
    name = _attr_name(el)
    isempty(name) && return nothing
    addr, spec, len, sign, endi, access, port = _extract_register_spec(el)
    representation = Symbol(_child_text(el, "Representation", "PureNumber"))

    meta = NodeMetadata()
    _extract_metadata!(meta, el)
    return IntRegNode(name, addr, len, sign, endi, access, port, spec,
        representation, meta)
end

function _parse_floatreg(el::EzXML.Node)
    name = _attr_name(el)
    isempty(name) && return nothing
    addr, spec, len, _, endi, access, port = _extract_register_spec(el)
    meta = NodeMetadata()
    _extract_metadata!(meta, el)
    return FloatRegNode(name, addr, len, endi, access, port, spec, meta)
end

function _parse_stringreg(el::EzXML.Node)
    name = _attr_name(el)
    isempty(name) && return nothing
    addr, spec, len, _, _, access, port = _extract_register_spec(el)
    meta = NodeMetadata()
    _extract_metadata!(meta, el)
    return StringRegNode(name, addr, len, access, port, spec, meta)
end

function _parse_register_raw(el::EzXML.Node)
    name = _attr_name(el)
    isempty(name) && return nothing
    addr, spec, len, _, _, access, port = _extract_register_spec(el)
    meta = NodeMetadata()
    _extract_metadata!(meta, el)
    return RegisterRawNode(name, addr, len, access, port, spec, meta)
end

function _parse_masked_intreg(el::EzXML.Node)
    name = _attr_name(el)
    isempty(name) && return nothing
    addr, spec, len, sign, endi, access, port = _extract_register_spec(el)

    lsb = -1; msb = -1
    for c in EzXML.eachelement(el)
        tag = EzXML.nodename(c)
        if tag == "Bit"
            b = _parse_integer_literal(EzXML.nodecontent(c))
            lsb = msb = Int(b)
        elseif tag == "LSB"
            lsb = Int(_parse_integer_literal(EzXML.nodecontent(c)))
        elseif tag == "MSB"
            msb = Int(_parse_integer_literal(EzXML.nodecontent(c)))
        end
    end
    (lsb >= 0 && msb >= 0) || return nothing

    meta = NodeMetadata()
    _extract_metadata!(meta, el)
    return MaskedIntRegNode(name, addr, len, sign, endi, access, port,
        lsb, msb, spec, meta)
end

function _parse_struct_reg(el::EzXML.Node)
    name = _attr_name(el)
    isempty(name) && return nothing
    addr, spec, len, sign, endi, access, port = _extract_register_spec(el)

    entries = StructEntryNode[]
    for c in EzXML.eachelement(el)
        tag = EzXML.nodename(c)
        tag == "StructEntry" || continue
        ename = _attr_name(c)
        isempty(ename) && continue
        elsb = -1; emsb = -1; esign = sign; eaccess = access
        for cc in EzXML.eachelement(c)
            ctag = EzXML.nodename(cc)
            if ctag == "Bit"
                b = _parse_integer_literal(EzXML.nodecontent(cc))
                elsb = emsb = Int(b)
            elseif ctag == "LSB"
                elsb = Int(_parse_integer_literal(EzXML.nodecontent(cc)))
            elseif ctag == "MSB"
                emsb = Int(_parse_integer_literal(EzXML.nodecontent(cc)))
            elseif ctag == "Sign"
                esign = String(strip(EzXML.nodecontent(cc))) == "Signed" ?
                    SIGNED : UNSIGNED
            elseif ctag == "AccessMode"
                eaccess = _parse_access(EzXML.nodecontent(cc))
            end
        end
        (elsb >= 0 && emsb >= 0) || continue
        emeta = NodeMetadata()
        _extract_metadata!(emeta, c)
        push!(entries, StructEntryNode(ename, name, nothing, esign, elsb, emsb,
            eaccess, emeta))
    end

    meta = NodeMetadata()
    _extract_metadata!(meta, el)
    return StructRegNode(name, addr, len, sign, endi, access, port,
        entries, spec, meta)
end

function _parse_enumeration(el::EzXML.Node)
    name = _attr_name(el)
    isempty(name) && return nothing

    pvalue = ""
    entries = EnumEntryNode[]
    for c in EzXML.eachelement(el)
        tag = EzXML.nodename(c)
        if tag == "pValue"
            pvalue = String(strip(EzXML.nodecontent(c)))
        elseif tag == "EnumEntry"
            ename = _attr_name(c)
            isempty(ename) && continue
            evalue = nothing
            ent_impl = ""; ent_avail = ""
            for cc in EzXML.eachelement(c)
                ctag = EzXML.nodename(cc)
                if ctag == "Value"
                    evalue = _parse_integer_literal(EzXML.nodecontent(cc))
                elseif ctag == "pIsImplemented"
                    ent_impl = String(strip(EzXML.nodecontent(cc)))
                elseif ctag == "pIsAvailable"
                    ent_avail = String(strip(EzXML.nodecontent(cc)))
                end
            end
            evalue === nothing && continue
            emeta = NodeMetadata()
            _extract_metadata!(emeta, c)
            push!(entries, EnumEntryNode(ename, evalue, ent_impl, ent_avail,
                nothing, nothing, emeta))
        end
    end
    isempty(pvalue) && return nothing

    meta = NodeMetadata()
    _extract_metadata!(meta, el)
    return EnumerationNode(name, pvalue, entries, nothing, meta)
end

function _parse_command(el::EzXML.Node)
    name = _attr_name(el)
    isempty(name) && return nothing

    pvalue = ""
    cmd_value = nothing
    cmd_value_name = ""

    for c in EzXML.eachelement(el)
        tag = EzXML.nodename(c)
        if tag == "pValue"
            pvalue = String(strip(EzXML.nodecontent(c)))
        elseif tag == "CommandValue"
            cmd_value = _parse_integer_literal(EzXML.nodecontent(c))
        elseif tag == "pCommandValue"
            cmd_value_name = String(strip(EzXML.nodecontent(c)))
        end
    end
    isempty(pvalue) && return nothing
    cmd_value === nothing && isempty(cmd_value_name) && return nothing

    meta = NodeMetadata()
    _extract_metadata!(meta, el)
    return CommandNode(name, pvalue,
        cmd_value === nothing ? Int64(0) : cmd_value,
        cmd_value_name, nothing, nothing, meta)
end

function _parse_swissknife(el::EzXML.Node; integer::Bool)
    name = _attr_name(el)
    isempty(name) && return nothing

    formula_src = ""
    variables = Pair{Symbol,String}[]
    constants_int = Dict{Symbol,Int64}()
    constants_float = Dict{Symbol,Float64}()

    for c in EzXML.eachelement(el)
        tag = EzXML.nodename(c)
        if tag == "Formula"
            formula_src = String(strip(EzXML.nodecontent(c)))
        elseif tag == "pVariable"
            varname = EzXML.haskey(c, "Name") ? String(c["Name"]) : ""
            target = String(strip(EzXML.nodecontent(c)))
            isempty(varname) || isempty(target) && continue
            push!(variables, Symbol(varname) => target)
        elseif tag == "Constant"
            cname = EzXML.haskey(c, "Name") ? String(c["Name"]) : ""
            isempty(cname) && continue
            text = strip(EzXML.nodecontent(c))
            if integer
                constants_int[Symbol(cname)] = _parse_integer_literal(text)
            else
                constants_float[Symbol(cname)] = parse(Float64, text)
            end
        end
    end
    isempty(formula_src) && return nothing

    meta = NodeMetadata()
    _extract_metadata!(meta, el)
    if integer
        return IntSwissKnifeNode(name, formula_src, nothing, variables,
            Pair{Symbol,Node}[], constants_int, meta)
    else
        return SwissKnifeNode(name, formula_src, nothing, variables,
            Pair{Symbol,Node}[], constants_float, meta)
    end
end

function _parse_converter(el::EzXML.Node; integer::Bool)
    name = _attr_name(el)
    isempty(name) && return nothing

    pvalue = ""
    formula_to = ""
    formula_from = ""
    variables = Pair{Symbol,String}[]
    constants_int = Dict{Symbol,Int64}()
    constants_float = Dict{Symbol,Float64}()
    is_linear = false
    representation = :PureNumber
    unit = ""

    for c in EzXML.eachelement(el)
        tag = EzXML.nodename(c)
        if tag == "pValue"
            pvalue = String(strip(EzXML.nodecontent(c)))
        elseif tag == "FormulaTo"
            formula_to = String(strip(EzXML.nodecontent(c)))
        elseif tag == "FormulaFrom"
            formula_from = String(strip(EzXML.nodecontent(c)))
        elseif tag == "pVariable"
            varname = EzXML.haskey(c, "Name") ? String(c["Name"]) : ""
            target = String(strip(EzXML.nodecontent(c)))
            isempty(varname) || isempty(target) && continue
            push!(variables, Symbol(varname) => target)
        elseif tag == "Constant"
            cname = EzXML.haskey(c, "Name") ? String(c["Name"]) : ""
            isempty(cname) && continue
            text = strip(EzXML.nodecontent(c))
            if integer
                constants_int[Symbol(cname)] = _parse_integer_literal(text)
            else
                constants_float[Symbol(cname)] = parse(Float64, text)
            end
        elseif tag == "IsLinear"
            is_linear = lowercase(strip(EzXML.nodecontent(c))) == "yes"
        elseif tag == "Representation"
            representation = Symbol(strip(EzXML.nodecontent(c)))
        elseif tag == "Unit"
            unit = String(strip(EzXML.nodecontent(c)))
        end
    end
    isempty(pvalue) && return nothing
    (isempty(formula_to) || isempty(formula_from)) && return nothing

    meta = NodeMetadata()
    _extract_metadata!(meta, el)
    if integer
        return IntConverterNode(name, pvalue, formula_to, formula_from,
            nothing, nothing, variables, Pair{Symbol,Node}[], constants_int,
            is_linear, representation, unit, nothing, meta)
    else
        return ConverterNode(name, pvalue, formula_to, formula_from,
            nothing, nothing, variables, Pair{Symbol,Node}[], constants_float,
            is_linear, representation, unit, nothing, meta)
    end
end

function _parse_category(el::EzXML.Node)
    name = _attr_name(el)
    isempty(name) && return nothing

    features = String[]
    for c in EzXML.eachelement(el)
        tag = EzXML.nodename(c)
        tag == "pFeature" && push!(features,
            String(strip(EzXML.nodecontent(c))))
    end

    meta = NodeMetadata()
    _extract_metadata!(meta, el)
    return CategoryNode(name, features, Node[], meta)
end

# ===========================================================================
# Pass 2 — bind reference fields
# ===========================================================================

function _resolve_refs!(nm::Nodemap)
    @inline lookup_opt(name) = haskey(nm, name) ? nm.nodes[name] : nothing

    for n in values(nm.nodes)
        # <pInvalidator>X</pInvalidator> on n: writes to X invalidate n.
        for inv_name in n.meta.invalidator_names
            target = lookup_opt(inv_name)
            target === nothing && continue
            push!(target.meta.invalidates, n)
        end
        # <pSelected>X</pSelected> on n: writes to n invalidate X.
        for sel_name in n.meta.selected_names
            selected = lookup_opt(sel_name)
            selected === nothing && continue
            push!(n.meta.invalidates, selected)
        end
        if !isempty(n.meta.is_implemented_name)
            n.meta.is_implemented_node = lookup_opt(n.meta.is_implemented_name)
        end
        if !isempty(n.meta.is_available_name)
            n.meta.is_available_node = lookup_opt(n.meta.is_available_name)
        end
        if !isempty(n.meta.is_locked_name)
            n.meta.is_locked_node = lookup_opt(n.meta.is_locked_name)
        end
    end

    # Per-type pValue / pMin / pMax / pInc / pVariable bindings
    for n in values(nm.nodes)
        _bind_pvalue!(n, nm)
    end

    # Resolve register address-spec pAddress/pIndex node references — we
    # don't actually need to store the resolved Node here because access.jl
    # looks them up by name through the nodemap each time. Keep the spec
    # untouched.

    # StructEntry → StructReg parent
    for n in values(nm.nodes)
        n isa StructRegNode || continue
        for entry in n.entries
            entry.parent_node = n
        end
    end

    # Category → child feature_nodes
    for n in values(nm.nodes)
        n isa CategoryNode || continue
        empty!(n.feature_nodes)
        for fname in n.features
            child = lookup_opt(fname)
            child === nothing || push!(n.feature_nodes, child)
        end
    end

    return nm
end

@inline _maybe_node(nm::Nodemap, name::AbstractString) =
    isempty(name) ? nothing : (haskey(nm, name) ? nm.nodes[name] : nothing)

function _bind_pvalue!(n::IntegerNode, nm::Nodemap)
    n.pvalue_node = _maybe_node(nm, n.pvalue)
    n.pmin_node = _maybe_node(nm, n.pmin_name)
    n.pmax_node = _maybe_node(nm, n.pmax_name)
    n.pinc_node = _maybe_node(nm, n.pinc_name)
end

function _bind_pvalue!(n::FloatNode, nm::Nodemap)
    n.pvalue_node = _maybe_node(nm, n.pvalue)
    n.pmin_node = _maybe_node(nm, n.pmin_name)
    n.pmax_node = _maybe_node(nm, n.pmax_name)
    n.pinc_node = _maybe_node(nm, n.pinc_name)
end

_bind_pvalue!(n::BooleanNode, nm::Nodemap) =
    (n.pvalue_node = _maybe_node(nm, n.pvalue); nothing)
_bind_pvalue!(n::StringNode, nm::Nodemap) =
    (n.pvalue_node = _maybe_node(nm, n.pvalue); nothing)
_bind_pvalue!(n::EnumerationNode, nm::Nodemap) = begin
    n.pvalue_node = _maybe_node(nm, n.pvalue)
    for e in n.entries
        e.is_implemented_node = _maybe_node(nm, e.is_implemented_name)
        e.is_available_node   = _maybe_node(nm, e.is_available_name)
    end
    nothing
end
function _bind_pvalue!(n::CommandNode, nm::Nodemap)
    n.pvalue_node = _maybe_node(nm, n.pvalue)
    n.command_value_node = _maybe_node(nm, n.command_value_name)
end

function _bind_pvalue!(n::ConverterNode, nm::Nodemap)
    n.pvalue_node = _maybe_node(nm, n.pvalue)
    empty!(n.variable_nodes)
    for (vname, target) in n.variables
        ref = _maybe_node(nm, target)
        ref === nothing || push!(n.variable_nodes, vname => ref)
    end
end

function _bind_pvalue!(n::IntConverterNode, nm::Nodemap)
    n.pvalue_node = _maybe_node(nm, n.pvalue)
    empty!(n.variable_nodes)
    for (vname, target) in n.variables
        ref = _maybe_node(nm, target)
        ref === nothing || push!(n.variable_nodes, vname => ref)
    end
end

function _bind_pvalue!(n::SwissKnifeNode, nm::Nodemap)
    empty!(n.variable_nodes)
    for (vname, target) in n.variables
        ref = _maybe_node(nm, target)
        ref === nothing || push!(n.variable_nodes, vname => ref)
    end
end

function _bind_pvalue!(n::IntSwissKnifeNode, nm::Nodemap)
    empty!(n.variable_nodes)
    for (vname, target) in n.variables
        ref = _maybe_node(nm, target)
        ref === nothing || push!(n.variable_nodes, vname => ref)
    end
end

# Default: nothing to bind (Categories, registers, struct entries handled
# elsewhere, EnumEntry).
_bind_pvalue!(::Node, ::Nodemap) = nothing

# ===========================================================================
# Pass 3 — compile formulas
# ===========================================================================

function _compile_formulas!(nm::Nodemap)
    for n in values(nm.nodes)
        _compile_formula!(n)
    end
    return nm
end

function _compile_formula!(n::SwissKnifeNode)
    n.formula_ast = parse_formula(n.formula_src)
end

function _compile_formula!(n::IntSwissKnifeNode)
    n.formula_ast = parse_formula(n.formula_src)
end

function _compile_formula!(n::ConverterNode)
    n.formula_to_ast = parse_formula(n.formula_to_src)
    n.formula_from_ast = parse_formula(n.formula_from_src)
end

function _compile_formula!(n::IntConverterNode)
    n.formula_to_ast = parse_formula(n.formula_to_src)
    n.formula_from_ast = parse_formula(n.formula_from_src)
end

_compile_formula!(::Node) = nothing  # non-formula nodes

# ===========================================================================
# Pass 4 — Category tree → ordered feature_names
# ===========================================================================

function _walk_category_tree(nm::Nodemap)
    seen = Set{String}()
    out = String[]

    function visit(node_name::AbstractString)
        haskey(nm, node_name) || return
        n = nm[String(node_name)]
        if n isa CategoryNode
            for f in n.features
                visit(f)
            end
        else
            n.name in seen && return
            push!(seen, n.name)
            is_feature(n) && push!(out, n.name)
        end
    end

    if haskey(nm, nm.root_category)
        visit(nm.root_category)
    end

    # Anything not reached from "Root" — append in declaration order so
    # `propertynames(cam)` is exhaustive even when the camera vendor
    # forgets a category linkage.
    for n in values(nm.nodes)
        is_feature(n) && !(n.name in seen) || continue
        push!(seen, n.name)
        push!(out, n.name)
    end

    return out
end
