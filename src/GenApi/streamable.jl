"""
Save / load camera settings — the GenApi `<Streamable>` mechanism.

Walks every `streamable=true` feature node in topological order
(selectors before selected) and emits / restores its current value.

Output format is a small XML document — easy to diff, easy to extend.
The choice of XML over JSON matches the GenApi convention; a JSON
encoder is trivial to drop in alongside if we ever need it.
"""

using EzXML

# ---------------------------------------------------------------------------
# Save
# ---------------------------------------------------------------------------

"""
    save_settings(io, nm, port, api)

Walk every streamable feature in `nm` (in `feature_names` order — which
already respects the Category tree, putting selectors near their
dependents) and write its current value to `io` as an XML document.
"""
function save_settings(io::IO, nm::Nodemap, port::PORT_HANDLE, api::ProducerAPI)
    println(io, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
    println(io, "<UserSet>")
    for fname in nm.feature_names
        haskey(nm, fname) || continue
        n = nm[fname]
        n.meta.streamable || continue
        try
            v = get_value(nm, fname, port, api)
            println(io, "  <Feature Name=\"", _xml_escape(fname), "\">",
                _xml_escape(_serialize_value(v)), "</Feature>")
        catch
            # Read errors are non-fatal — skip the feature so a single bad
            # node doesn't lose the whole snapshot.
        end
    end
    println(io, "</UserSet>")
    return io
end

"""
    load_settings(io, nm, port, api)

Inverse of `save_settings`: parse an XML snapshot from `io` and write each
listed feature back to the camera. Features not present in `nm` are
skipped silently.
"""
function load_settings(io::IO, nm::Nodemap, port::PORT_HANDLE, api::ProducerAPI)
    text = read(io, String)
    doc = EzXML.parsexml(text)
    root_el = EzXML.root(doc)
    for c in EzXML.eachelement(root_el)
        EzXML.nodename(c) == "Feature" || continue
        EzXML.haskey(c, "Name") || continue
        fname = String(c["Name"])
        haskey(nm, fname) || continue
        raw = strip(EzXML.nodecontent(c))
        n = nm[fname]
        try
            value = _parse_serialized_value(n, raw)
            set_value!(nm, fname, value, port, api)
        catch
            # Skip features that don't take, log? For now silent.
        end
    end
    return nm
end

# ---------------------------------------------------------------------------
# Value (de-)serialization
# ---------------------------------------------------------------------------

_serialize_value(v::Integer) = string(v)
_serialize_value(v::AbstractFloat) = string(v)
_serialize_value(v::Bool) = v ? "true" : "false"
_serialize_value(v::AbstractString) = String(v)
_serialize_value(v) = string(v)

function _parse_serialized_value(n::Node, raw::AbstractString)
    if n isa IntegerNode || n isa IntConverterNode || n isa IntSwissKnifeNode
        return _parse_integer_literal(raw)
    elseif n isa FloatNode || n isa ConverterNode || n isa SwissKnifeNode
        return parse(Float64, raw)
    elseif n isa BooleanNode
        return lowercase(raw) in ("true", "1", "yes")
    elseif n isa EnumerationNode
        return String(raw)              # entry name
    elseif n isa StringNode
        return String(raw)
    end
    return String(raw)
end

# ---------------------------------------------------------------------------
# Minimal XML escaping (avoid pulling in a full library for 4 entities)
# ---------------------------------------------------------------------------

function _xml_escape(s::AbstractString)
    out = IOBuffer()
    for c in s
        if     c == '&';  print(out, "&amp;")
        elseif c == '<';  print(out, "&lt;")
        elseif c == '>';  print(out, "&gt;")
        elseif c == '"';  print(out, "&quot;")
        else              print(out, c)
        end
    end
    return String(take!(out))
end
