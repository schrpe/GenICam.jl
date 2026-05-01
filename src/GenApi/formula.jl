"""
SwissKnife / IntSwissKnife formula evaluator.

This is the GenApi mini-expression-language used by `<SwissKnife>`,
`<IntSwissKnife>`, `<Converter>`, and `<IntConverter>` nodes — plus a few
boolean nodes (`<pIsAvailable>` etc. occasionally use it). The dialect:

  * **Operators** (highest to lowest precedence):
    1. parentheses, function calls
    2. unary `-`, `~`, `!`
    3. `**` (right-assoc)
    4. `*`, `/`, `%`
    5. `+`, `-`
    6. `<<`, `>>`
    7. `&`
    8. `^`
    9. `|`
    10. `<`, `>`, `<=`, `>=`, `==` / `=`, `!=` / `<>`
    11. `&&`
    12. `||`
    13. `?:` (right-assoc)

  * **Functions**:
    - SwissKnife (Float64): `SIN COS TAN ASIN ACOS ATAN EXP LN LG SQRT CEIL
      FLOOR ROUND TRUNC ABS SGN NEG ATAN2`
    - IntSwissKnife (Int64): only `ABS SGN NEG` plus all operators with
      integer semantics (`/` is `div`, no trig/exp).

  * **Constants**: `PI`, `E` (case-sensitive).

  * **Numbers**: decimal integer (`42`), hex (`0xFF`), or floating-point
    (`1.5`, `1.5e-3`).

  * **Variables**: any identifier other than the reserved constants and
    function names. Bound at evaluation time via `EvalContext`.

The parser produces an AST (immutable structs) once at XML-load time; the
evaluators walk it for every read. Two evaluators share one AST so
`<Converter>` (Float) and `<IntConverter>` (Int) can both be expressed.
"""

# ---------------------------------------------------------------------------
# Tokens
# ---------------------------------------------------------------------------

@enum TokenKind::Int8 begin
    TOK_NUM_INT
    TOK_NUM_FLOAT
    TOK_IDENT
    TOK_LPAREN
    TOK_RPAREN
    TOK_COMMA
    TOK_QUESTION
    TOK_COLON
    TOK_PLUS
    TOK_MINUS
    TOK_STAR
    TOK_POW           # **
    TOK_SLASH
    TOK_PERCENT
    TOK_TILDE         # ~
    TOK_BANG          # !
    TOK_AMP           # &
    TOK_PIPE          # |
    TOK_CARET         # ^
    TOK_SHL           # <<
    TOK_SHR           # >>
    TOK_AND           # &&
    TOK_OR            # ||
    TOK_LT
    TOK_GT
    TOK_LE
    TOK_GE
    TOK_EQ            # == or =
    TOK_NEQ           # != or <>
    TOK_EOF
end

struct Token
    kind::TokenKind
    int_value::Int64
    float_value::Float64
    text::String
    pos::Int          # 1-based source position; for error messages
end

# ---------------------------------------------------------------------------
# Tokenizer
# ---------------------------------------------------------------------------

"""
    FormulaParseError <: Exception

Raised at XML-load time when a `<Formula>` / `<FormulaTo>` /
`<FormulaFrom>` text is unparseable (mismatched parentheses,
unexpected character, malformed number literal, ...). Carries the
source string and the offending position, so error messages can show
where the problem is.
"""
struct FormulaParseError <: Exception
    message::String
    source::String
    pos::Int
end

function Base.showerror(io::IO, e::FormulaParseError)
    print(io, "FormulaParseError at position ", e.pos, ": ", e.message)
    if !isempty(e.source)
        print(io, "\n  in: ", e.source)
        print(io, "\n      ", " "^(e.pos - 1), "^")
    end
end

"""
    tokenize(src) -> Vector{Token}

Eagerly turn a formula string into a token stream. Whitespace is skipped.
Returns ending with a single `TOK_EOF` token to simplify the parser's
look-ahead.
"""
function tokenize(src::AbstractString)
    s = String(src)
    tokens = Token[]
    i = 1
    n = sizeof(s)
    while i <= n
        c = s[i]
        if isspace(c)
            i = nextind(s, i)
            continue
        end

        # Numbers (must be checked before identifiers because hex starts with '0')
        if isdigit(c) || (c == '.' && i < n && isdigit(s[nextind(s, i)]))
            tok, i = _scan_number(s, i)
            push!(tokens, tok)
            continue
        end

        # Identifiers (variables, functions, constants)
        if _is_ident_start(c)
            tok, i = _scan_ident(s, i)
            push!(tokens, tok)
            continue
        end

        # Multi-char and single-char operators
        tok, i = _scan_operator(s, i, n)
        push!(tokens, tok)
    end
    push!(tokens, Token(TOK_EOF, 0, 0.0, "", n + 1))
    return tokens
end

@inline _is_ident_start(c::Char) = isletter(c) || c == '_'
@inline _is_ident_cont(c::Char)  = isletter(c) || isdigit(c) || c == '_'

function _scan_number(s::String, start::Int)
    n = sizeof(s)
    i = start

    # Hex literal: 0x or 0X prefix
    if s[i] == '0' && i < n
        nxt = s[nextind(s, i)]
        if nxt == 'x' || nxt == 'X'
            j = nextind(s, nextind(s, i))   # skip 0x
            hex_start = j
            while j <= n && (isdigit(s[j]) ||
                             ('a' <= lowercase(s[j]) <= 'f'))
                j = nextind(s, j)
            end
            j == hex_start && throw(FormulaParseError(
                "expected hex digits after 0x", s, start))
            text = s[hex_start:prevind(s, j)]
            return (Token(TOK_NUM_INT, Int64(parse(UInt64, text; base = 16)),
                0.0, text, start), j)
        end
    end

    # Decimal / float
    j = i
    has_dot = false
    has_exp = false
    while j <= n && isdigit(s[j])
        j = nextind(s, j)
    end
    if j <= n && s[j] == '.'
        has_dot = true
        j = nextind(s, j)
        while j <= n && isdigit(s[j])
            j = nextind(s, j)
        end
    end
    if j <= n && (s[j] == 'e' || s[j] == 'E')
        has_exp = true
        j = nextind(s, j)
        if j <= n && (s[j] == '+' || s[j] == '-')
            j = nextind(s, j)
        end
        exp_start = j
        while j <= n && isdigit(s[j])
            j = nextind(s, j)
        end
        j == exp_start && throw(FormulaParseError(
            "expected digits in exponent", s, start))
    end

    text = s[i:prevind(s, j)]
    if has_dot || has_exp
        return (Token(TOK_NUM_FLOAT, 0, parse(Float64, text), text, start), j)
    else
        return (Token(TOK_NUM_INT, parse(Int64, text), 0.0, text, start), j)
    end
end

function _scan_ident(s::String, start::Int)
    n = sizeof(s)
    j = start
    while j <= n && _is_ident_cont(s[j])
        j = nextind(s, j)
    end
    text = s[start:prevind(s, j)]
    return (Token(TOK_IDENT, 0, 0.0, text, start), j)
end

function _scan_operator(s::String, start::Int, n::Int)
    c = s[start]
    nxt = start < n ? s[nextind(s, start)] : '\0'
    j = nextind(s, start)

    # 2-char operators first
    if c == '*' && nxt == '*'
        return (Token(TOK_POW, 0, 0.0, "**", start), nextind(s, j))
    elseif c == '<' && nxt == '<'
        return (Token(TOK_SHL, 0, 0.0, "<<", start), nextind(s, j))
    elseif c == '>' && nxt == '>'
        return (Token(TOK_SHR, 0, 0.0, ">>", start), nextind(s, j))
    elseif c == '<' && nxt == '='
        return (Token(TOK_LE, 0, 0.0, "<=", start), nextind(s, j))
    elseif c == '>' && nxt == '='
        return (Token(TOK_GE, 0, 0.0, ">=", start), nextind(s, j))
    elseif c == '=' && nxt == '='
        return (Token(TOK_EQ, 0, 0.0, "==", start), nextind(s, j))
    elseif c == '!' && nxt == '='
        return (Token(TOK_NEQ, 0, 0.0, "!=", start), nextind(s, j))
    elseif c == '<' && nxt == '>'
        return (Token(TOK_NEQ, 0, 0.0, "<>", start), nextind(s, j))
    elseif c == '&' && nxt == '&'
        return (Token(TOK_AND, 0, 0.0, "&&", start), nextind(s, j))
    elseif c == '|' && nxt == '|'
        return (Token(TOK_OR, 0, 0.0, "||", start), nextind(s, j))
    end

    # 1-char operators
    if     c == '+'  return (Token(TOK_PLUS, 0, 0.0, "+", start), j)
    elseif c == '-'  return (Token(TOK_MINUS, 0, 0.0, "-", start), j)
    elseif c == '*'  return (Token(TOK_STAR, 0, 0.0, "*", start), j)
    elseif c == '/'  return (Token(TOK_SLASH, 0, 0.0, "/", start), j)
    elseif c == '%'  return (Token(TOK_PERCENT, 0, 0.0, "%", start), j)
    elseif c == '~'  return (Token(TOK_TILDE, 0, 0.0, "~", start), j)
    elseif c == '!'  return (Token(TOK_BANG, 0, 0.0, "!", start), j)
    elseif c == '&'  return (Token(TOK_AMP, 0, 0.0, "&", start), j)
    elseif c == '|'  return (Token(TOK_PIPE, 0, 0.0, "|", start), j)
    elseif c == '^'  return (Token(TOK_CARET, 0, 0.0, "^", start), j)
    elseif c == '<'  return (Token(TOK_LT, 0, 0.0, "<", start), j)
    elseif c == '>'  return (Token(TOK_GT, 0, 0.0, ">", start), j)
    elseif c == '='  return (Token(TOK_EQ, 0, 0.0, "=", start), j)
    elseif c == '('  return (Token(TOK_LPAREN, 0, 0.0, "(", start), j)
    elseif c == ')'  return (Token(TOK_RPAREN, 0, 0.0, ")", start), j)
    elseif c == ','  return (Token(TOK_COMMA, 0, 0.0, ",", start), j)
    elseif c == '?'  return (Token(TOK_QUESTION, 0, 0.0, "?", start), j)
    elseif c == ':'  return (Token(TOK_COLON, 0, 0.0, ":", start), j)
    end
    throw(FormulaParseError("unexpected character $(repr(c))", s, start))
end

# ---------------------------------------------------------------------------
# AST
# (`FormulaAST` itself is declared in `GenApi.jl` so types.jl can reference
# it as a field type before formula.jl is included.)
# ---------------------------------------------------------------------------

struct NumLitInt <: FormulaAST
    value::Int64
end
struct NumLitFloat <: FormulaAST
    value::Float64
end
struct VarRef <: FormulaAST
    name::Symbol
end
struct Unary <: FormulaAST
    op::Symbol
    child::FormulaAST
end
struct Binary <: FormulaAST
    op::Symbol
    lhs::FormulaAST
    rhs::FormulaAST
end
struct Ternary <: FormulaAST
    cond::FormulaAST
    then_::FormulaAST
    else_::FormulaAST
end
struct Call <: FormulaAST
    func::Symbol
    args::Vector{FormulaAST}
end

# ---------------------------------------------------------------------------
# Pratt parser
#
# Each token kind has a "left binding power" (LBP) used when it appears in
# infix position. Some kinds also have a `nud` (null denotation, prefix
# action) such as numbers, identifiers, parens, and unary operators.
#
# Precedence levels (matches the docstring at top of file):
#   ternary  ?:       10  (right-assoc)
#   ||                20
#   &&                30
#   == != = <>        40
#   < > <= >=         50
#   |                 60
#   ^                 70
#   &                 80
#   << >>             90
#   + -              100
#   * / %            110
#   **               120 (right-assoc)
#   unary            130
#   parens / call    140
# ---------------------------------------------------------------------------

const _BP_TERNARY  = 10
const _BP_OR       = 20
const _BP_AND      = 30
const _BP_EQ       = 40
const _BP_REL      = 50
const _BP_BITOR    = 60
const _BP_BITXOR   = 70
const _BP_BITAND   = 80
const _BP_SHIFT    = 90
const _BP_ADD      = 100
const _BP_MUL      = 110
const _BP_POW      = 120
const _BP_UNARY    = 130

mutable struct _Parser
    tokens::Vector{Token}
    pos::Int        # index into tokens
    src::String     # original source (for error messages)
end

@inline _peek(p::_Parser) = p.tokens[p.pos]
@inline function _consume(p::_Parser)
    t = p.tokens[p.pos]
    p.pos += 1
    return t
end

function _expect(p::_Parser, kind::TokenKind, what::AbstractString)
    t = _peek(p)
    t.kind === kind || throw(FormulaParseError(
        "expected $what, got $(t.text === "" ? "$(t.kind)" : repr(t.text))",
        p.src, t.pos))
    return _consume(p)
end

"""
    parse_formula(src) -> FormulaAST

Parse a SwissKnife / Converter formula string into an AST. Throws
`FormulaParseError` on any lex / parse problem.
"""
function parse_formula(src::AbstractString)
    s = String(src)
    p = _Parser(tokenize(s), 1, s)
    expr = _parse_expr(p, 0)
    t = _peek(p)
    t.kind === TOK_EOF || throw(FormulaParseError(
        "unexpected token after expression: $(repr(t.text))", s, t.pos))
    return expr
end

# Pratt main loop: parse a left-hand side then chain infix operators whose
# binding power exceeds the caller's "right" binding power.
function _parse_expr(p::_Parser, rbp::Int)
    left = _parse_nud(p)
    while _lbp(_peek(p)) > rbp
        left = _parse_led(p, left)
    end
    return left
end

# nud: what to do when this token starts an expression.
function _parse_nud(p::_Parser)
    t = _consume(p)
    if t.kind === TOK_NUM_INT
        return NumLitInt(t.int_value)
    elseif t.kind === TOK_NUM_FLOAT
        return NumLitFloat(t.float_value)
    elseif t.kind === TOK_IDENT
        # Function call  vs.  bare variable
        if _peek(p).kind === TOK_LPAREN
            _consume(p)  # (
            args = FormulaAST[]
            if _peek(p).kind !== TOK_RPAREN
                push!(args, _parse_expr(p, 0))
                while _peek(p).kind === TOK_COMMA
                    _consume(p)
                    push!(args, _parse_expr(p, 0))
                end
            end
            _expect(p, TOK_RPAREN, "')'")
            return Call(Symbol(t.text), args)
        end
        return VarRef(Symbol(t.text))
    elseif t.kind === TOK_LPAREN
        e = _parse_expr(p, 0)
        _expect(p, TOK_RPAREN, "')'")
        return e
    elseif t.kind === TOK_MINUS
        return Unary(:neg, _parse_expr(p, _BP_UNARY))
    elseif t.kind === TOK_PLUS
        return _parse_expr(p, _BP_UNARY)        # unary + is a no-op
    elseif t.kind === TOK_TILDE
        return Unary(:bitnot, _parse_expr(p, _BP_UNARY))
    elseif t.kind === TOK_BANG
        return Unary(:not, _parse_expr(p, _BP_UNARY))
    end
    throw(FormulaParseError(
        "unexpected token at start of expression: $(repr(t.text))",
        p.src, t.pos))
end

# led: how to parse the rest after seeing this infix operator.
function _parse_led(p::_Parser, left::FormulaAST)
    t = _consume(p)
    k = t.kind

    # Ternary is right-associative and "splits" into ?then:else.
    if k === TOK_QUESTION
        then_ = _parse_expr(p, _BP_TERNARY - 1)   # right-assoc → use lbp-1
        _expect(p, TOK_COLON, "':' in ternary")
        else_ = _parse_expr(p, _BP_TERNARY - 1)
        return Ternary(left, then_, else_)
    end

    # Power is right-associative.
    if k === TOK_POW
        rhs = _parse_expr(p, _BP_POW - 1)
        return Binary(:pow, left, rhs)
    end

    op = _binop_symbol(k)
    bp = _lbp_kind(k)
    rhs = _parse_expr(p, bp)
    return Binary(op, left, rhs)
end

# Binding power of the *current* token when seen in infix position.
@inline _lbp(t::Token) = _lbp_kind(t.kind)

function _lbp_kind(k::TokenKind)::Int
    if k === TOK_QUESTION             return _BP_TERNARY
    elseif k === TOK_OR               return _BP_OR
    elseif k === TOK_AND              return _BP_AND
    elseif k === TOK_EQ || k === TOK_NEQ
                                       return _BP_EQ
    elseif k === TOK_LT || k === TOK_GT || k === TOK_LE || k === TOK_GE
                                       return _BP_REL
    elseif k === TOK_PIPE             return _BP_BITOR
    elseif k === TOK_CARET            return _BP_BITXOR
    elseif k === TOK_AMP              return _BP_BITAND
    elseif k === TOK_SHL || k === TOK_SHR
                                       return _BP_SHIFT
    elseif k === TOK_PLUS || k === TOK_MINUS
                                       return _BP_ADD
    elseif k === TOK_STAR || k === TOK_SLASH || k === TOK_PERCENT
                                       return _BP_MUL
    elseif k === TOK_POW              return _BP_POW
    end
    return 0
end

function _binop_symbol(k::TokenKind)::Symbol
    k === TOK_OR      && return :or
    k === TOK_AND     && return :and
    k === TOK_EQ      && return :eq
    k === TOK_NEQ     && return :neq
    k === TOK_LT      && return :lt
    k === TOK_GT      && return :gt
    k === TOK_LE      && return :le
    k === TOK_GE      && return :ge
    k === TOK_PIPE    && return :bitor
    k === TOK_CARET   && return :bitxor
    k === TOK_AMP     && return :bitand
    k === TOK_SHL     && return :shl
    k === TOK_SHR     && return :shr
    k === TOK_PLUS    && return :add
    k === TOK_MINUS   && return :sub
    k === TOK_STAR    && return :mul
    k === TOK_SLASH   && return :div
    k === TOK_PERCENT && return :mod
    k === TOK_POW     && return :pow
    throw(ArgumentError("token kind $k has no infix mapping"))
end

# ---------------------------------------------------------------------------
# Evaluator
# ---------------------------------------------------------------------------

"""
    FormulaEvalError <: Exception

Raised at read/write time for runtime issues in a SwissKnife or
Converter formula evaluation: divide-by-zero, using a Float-only
function (`SQRT`/`SIN`/`PI`/...) inside an `IntSwissKnife`, undefined
variable, etc. The formula's parse-time validity is enforced by
`FormulaParseError` instead.
"""
struct FormulaEvalError <: Exception
    message::String
end
Base.showerror(io::IO, e::FormulaEvalError) =
    print(io, "FormulaEvalError: ", e.message)

"""
    EvalContext

Bundles the variable lookup callback used by the evaluator. `lookup(name)`
must return a `Real` (Int or Float); for nested SwissKnife / IntReg /
Converter chains the callback walks the nodemap recursively. The
`visiting` set is the recursion guard — pre-populate it with the root
node's name before evaluating.
"""
mutable struct EvalContext
    lookup::Function          # (Symbol) -> Real
    visiting::Set{String}
end

EvalContext(lookup::Function) = EvalContext(lookup, Set{String}())

EvalContext(vars::Dict{Symbol,<:Real}) =
    EvalContext(name -> get(vars, name) do
        throw(FormulaEvalError("undefined variable: $name"))
    end)

# ----- IntSwissKnife / IntConverter — strict Int64 with floor semantics ----

"""
    eval_int(ast, ctx) -> Int64

Evaluate an AST as IntSwissKnife / IntConverter — pure 64-bit signed integer
arithmetic. Each operation truncates intermediate floats to `Int64` (per
GenApi spec). Functions limited to `ABS / SGN / NEG`; trig/exp/log raise.
"""
function eval_int(ast::FormulaAST, ctx::EvalContext)
    return _eval_i(ast, ctx)
end

_eval_i(n::NumLitInt, ::EvalContext)   = n.value
_eval_i(n::NumLitFloat, ::EvalContext) = Int64(floor(n.value))

function _eval_i(n::VarRef, ctx::EvalContext)
    n.name === :PI && throw(FormulaEvalError(
        "PI is not valid in IntSwissKnife/IntConverter formulas"))
    n.name === :E && throw(FormulaEvalError(
        "E is not valid in IntSwissKnife/IntConverter formulas"))
    v = ctx.lookup(n.name)
    return v isa Integer ? Int64(v) : Int64(floor(Float64(v)))
end

function _eval_i(n::Unary, ctx::EvalContext)
    x = _eval_i(n.child, ctx)
    if     n.op === :neg     return -x
    elseif n.op === :bitnot  return ~x
    elseif n.op === :not     return x == 0 ? Int64(1) : Int64(0)
    end
    throw(FormulaEvalError("unknown unary op: $(n.op)"))
end

function _eval_i(n::Binary, ctx::EvalContext)
    # Short-circuit logical operators
    if n.op === :and
        a = _eval_i(n.lhs, ctx)
        a == 0 && return Int64(0)
        return _eval_i(n.rhs, ctx) == 0 ? Int64(0) : Int64(1)
    elseif n.op === :or
        a = _eval_i(n.lhs, ctx)
        a != 0 && return Int64(1)
        return _eval_i(n.rhs, ctx) != 0 ? Int64(1) : Int64(0)
    end

    a = _eval_i(n.lhs, ctx)
    b = _eval_i(n.rhs, ctx)

    if     n.op === :add     return a + b
    elseif n.op === :sub     return a - b
    elseif n.op === :mul     return a * b
    elseif n.op === :div     b == 0 && throw(FormulaEvalError("integer divide by zero"))
                              return div(a, b)
    elseif n.op === :mod     b == 0 && throw(FormulaEvalError("integer modulo by zero"))
                              return mod(a, b)
    elseif n.op === :pow     return Int64(floor(Float64(a) ^ Float64(b)))
    elseif n.op === :shl     return a << b
    elseif n.op === :shr     return a >> b
    elseif n.op === :bitand  return a & b
    elseif n.op === :bitor   return a | b
    elseif n.op === :bitxor  return a ⊻ b
    elseif n.op === :eq      return a == b ? Int64(1) : Int64(0)
    elseif n.op === :neq     return a != b ? Int64(1) : Int64(0)
    elseif n.op === :lt      return a <  b ? Int64(1) : Int64(0)
    elseif n.op === :gt      return a >  b ? Int64(1) : Int64(0)
    elseif n.op === :le      return a <= b ? Int64(1) : Int64(0)
    elseif n.op === :ge      return a >= b ? Int64(1) : Int64(0)
    end
    throw(FormulaEvalError("unknown binary op: $(n.op)"))
end

function _eval_i(n::Ternary, ctx::EvalContext)
    return _eval_i(n.cond, ctx) != 0 ?
        _eval_i(n.then_, ctx) : _eval_i(n.else_, ctx)
end

function _eval_i(n::Call, ctx::EvalContext)
    f = n.func
    if     f === :ABS && length(n.args) == 1
        return abs(_eval_i(n.args[1], ctx))
    elseif f === :SGN && length(n.args) == 1
        x = _eval_i(n.args[1], ctx)
        return x > 0 ? Int64(1) : (x < 0 ? Int64(-1) : Int64(0))
    elseif f === :NEG && length(n.args) == 1
        return -_eval_i(n.args[1], ctx)
    end
    # Constants
    if length(n.args) == 0
        f === :PI && throw(FormulaEvalError("PI is not valid in IntSwissKnife"))
        f === :E  && throw(FormulaEvalError("E is not valid in IntSwissKnife"))
    end
    throw(FormulaEvalError(
        "function $f is not supported in IntSwissKnife/IntConverter"))
end

# ----- SwissKnife / Converter — Float64 throughout -----

"""
    eval_float(ast, ctx) -> Float64

Evaluate an AST as SwissKnife / Converter — IEEE 754 double-precision.
Supports the full math library (`SIN`, `COS`, `EXP`, `LN`, `SQRT`, ...) and
constants (`PI`, `E`).
"""
function eval_float(ast::FormulaAST, ctx::EvalContext)
    return _eval_f(ast, ctx)
end

_eval_f(n::NumLitInt, ::EvalContext)   = Float64(n.value)
_eval_f(n::NumLitFloat, ::EvalContext) = n.value

function _eval_f(n::VarRef, ctx::EvalContext)
    n.name === :PI && return Float64(pi)
    n.name === :E  && return Float64(MathConstants.e)
    v = ctx.lookup(n.name)
    return Float64(v)
end

function _eval_f(n::Unary, ctx::EvalContext)
    x = _eval_f(n.child, ctx)
    if     n.op === :neg     return -x
    elseif n.op === :bitnot  return Float64(~Int64(floor(x)))
    elseif n.op === :not     return x == 0.0 ? 1.0 : 0.0
    end
    throw(FormulaEvalError("unknown unary op: $(n.op)"))
end

function _eval_f(n::Binary, ctx::EvalContext)
    if n.op === :and
        a = _eval_f(n.lhs, ctx)
        a == 0.0 && return 0.0
        return _eval_f(n.rhs, ctx) == 0.0 ? 0.0 : 1.0
    elseif n.op === :or
        a = _eval_f(n.lhs, ctx)
        a != 0.0 && return 1.0
        return _eval_f(n.rhs, ctx) != 0.0 ? 1.0 : 0.0
    end

    a = _eval_f(n.lhs, ctx)
    b = _eval_f(n.rhs, ctx)

    if     n.op === :add     return a + b
    elseif n.op === :sub     return a - b
    elseif n.op === :mul     return a * b
    elseif n.op === :div     return a / b
    elseif n.op === :mod     return mod(a, b)
    elseif n.op === :pow     return a ^ b
    elseif n.op === :shl     return Float64(Int64(floor(a)) << Int64(floor(b)))
    elseif n.op === :shr     return Float64(Int64(floor(a)) >> Int64(floor(b)))
    elseif n.op === :bitand  return Float64(Int64(floor(a)) & Int64(floor(b)))
    elseif n.op === :bitor   return Float64(Int64(floor(a)) | Int64(floor(b)))
    elseif n.op === :bitxor  return Float64(Int64(floor(a)) ⊻ Int64(floor(b)))
    elseif n.op === :eq      return a == b ? 1.0 : 0.0
    elseif n.op === :neq     return a != b ? 1.0 : 0.0
    elseif n.op === :lt      return a <  b ? 1.0 : 0.0
    elseif n.op === :gt      return a >  b ? 1.0 : 0.0
    elseif n.op === :le      return a <= b ? 1.0 : 0.0
    elseif n.op === :ge      return a >= b ? 1.0 : 0.0
    end
    throw(FormulaEvalError("unknown binary op: $(n.op)"))
end

function _eval_f(n::Ternary, ctx::EvalContext)
    return _eval_f(n.cond, ctx) != 0.0 ?
        _eval_f(n.then_, ctx) : _eval_f(n.else_, ctx)
end

function _eval_f(n::Call, ctx::EvalContext)
    f = n.func
    # Constants — zero-arg calls
    if length(n.args) == 0
        f === :PI && return Float64(pi)
        f === :E  && return Float64(MathConstants.e)
        throw(FormulaEvalError("unknown zero-arg function: $f"))
    end

    # Single-arg math
    if length(n.args) == 1
        x = _eval_f(n.args[1], ctx)
        if     f === :ABS    return abs(x)
        elseif f === :SGN    return sign(x)
        elseif f === :NEG    return -x
        elseif f === :SIN    return sin(x)
        elseif f === :COS    return cos(x)
        elseif f === :TAN    return tan(x)
        elseif f === :ASIN   return asin(x)
        elseif f === :ACOS   return acos(x)
        elseif f === :ATAN   return atan(x)
        elseif f === :EXP    return exp(x)
        elseif f === :LN     return log(x)
        elseif f === :LG     return log10(x)
        elseif f === :SQRT   return sqrt(x)
        elseif f === :CEIL   return ceil(x)
        elseif f === :FLOOR  return floor(x)
        elseif f === :ROUND  return round(x)
        elseif f === :TRUNC  return trunc(x)
        end
    end

    # Two-arg math
    if length(n.args) == 2
        a = _eval_f(n.args[1], ctx)
        b = _eval_f(n.args[2], ctx)
        f === :ATAN2 && return atan(a, b)
        # ROUND with precision: ROUND(x, digits)
        f === :ROUND && return round(a; digits = Int(floor(b)))
    end

    throw(FormulaEvalError(
        "unknown function $f with $(length(n.args)) argument(s)"))
end

# ---------------------------------------------------------------------------
# Convenience: parse + evaluate in one shot (used by tests and one-off calls)
# ---------------------------------------------------------------------------

"""
    evaluate_int(formula, vars::Dict{Symbol,<:Real}) -> Int64
    evaluate_float(formula, vars::Dict{Symbol,<:Real}) -> Float64

Parse and evaluate `formula` against an explicit variable table. Convenience
wrappers around `parse_formula` + `eval_int` / `eval_float`.
"""
evaluate_int(src::AbstractString, vars::Dict{Symbol,<:Real} = Dict{Symbol,Real}()) =
    eval_int(parse_formula(src), EvalContext(vars))

evaluate_float(src::AbstractString, vars::Dict{Symbol,<:Real} = Dict{Symbol,Real}()) =
    eval_float(parse_formula(src), EvalContext(vars))
