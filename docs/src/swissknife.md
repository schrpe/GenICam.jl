```@meta
CurrentModule = GenICam
```

# The SwissKnife formula language

Camera vendors don't always expose features as simple registers.
Sometimes a "feature" is computed from several others: `MaxExposure`
might be `1_000_000 / FrameRate`; `EffectiveBandwidth` might be a
piecewise function of `PixelFormat`, `Width`, and `Height`; the
hardware register address itself might be `BaseAddress + ChannelIndex
* 4`.

GenApi expresses these computations in two node types:

  * `<SwissKnife>` (Float) and `<IntSwissKnife>` (Int) — pure
    computed values: read-only, take some `pVariable` inputs, evaluate
    a `<Formula>`, return a number.
  * `<Converter>` (Float) and `<IntConverter>` (Int) — bidirectional
    bridge over a backing register: a `<FormulaFrom>` for read
    (register-units → user-units) and a `<FormulaTo>` for write
    (user-units → register-units).

Both node families share the same expression language — a small but
non-trivial mini-language defined inside the GenApi standard.
`GenICam.jl` parses every formula at XML-load time into a cached AST,
then walks the AST on each read or write. The full operator set, all
spec'd functions, and both Int and Float evaluators are implemented;
this page documents what's supported.

## Number literals

| Form | Example | Type |
|---|---|---|
| Decimal integer | `42`, `-7` | `Int64` |
| Hexadecimal | `0xFF`, `0x1FFFE` | `Int64` (decoded as `UInt64` then reinterpreted) |
| Decimal float | `1.5`, `-3.14` | `Float64` |
| Scientific notation | `1.5e3`, `2.0E-7` | `Float64` |

In an `IntSwissKnife` / `IntConverter`, float literals are truncated to
`Int64` on use (per spec).

## Operators

Highest precedence first; same-row entries are equal.

| Level | Operators | Associativity | Notes |
|---:|---|---|---|
| 1 (high) | `(...)`, function call `f(args)` | n/a | grouping |
| 2 | unary `-`, `~`, `!` | right | numeric negate / bitwise NOT / logical NOT |
| 3 | `**` | right | exponent (right-associative: `2**3**2 == 2**9 == 512`) |
| 4 | `*`, `/`, `%` | left | int `/` is `div` (truncate toward zero); float `/` is regular |
| 5 | `+`, `-` | left | binary |
| 6 | `<<`, `>>` | left | bit shifts |
| 7 | `&` | left | bitwise AND |
| 8 | `^` | left | bitwise XOR (caret means XOR here, not power!) |
| 9 | `\|` | left | bitwise OR |
| 10 | `<`, `>`, `<=`, `>=`, `==`/`=`, `!=`/`<>` | left | comparison; `=` and `<>` are GenApi spellings of `==` and `!=` |
| 11 | `&&` | left | short-circuit logical AND |
| 12 | `\|\|` | left | short-circuit logical OR |
| 13 (low) | `cond ? then : else` | right | ternary; nests right-associatively |

Two surprises worth keeping in mind:

  * `^` is **bitwise XOR**, not exponentiation. Use `**` for power.
  * `&&` / `\|\|` short-circuit; `&` / `\|` always evaluate both sides.
    For predicates this matters when the right-hand side has side
    effects through `pVariable` (i.e. triggers a register read).

## Built-in functions

### Available everywhere

  * `ABS(x)` — absolute value
  * `SGN(x)` — sign: `-1` / `0` / `1`
  * `NEG(x)` — unary negate (same as `-x`)

### Available only in `SwissKnife` / `Converter` (Float64 evaluator)

| Function | Description |
|---|---|
| `SIN(x)`, `COS(x)`, `TAN(x)` | trig (radians) |
| `ASIN(x)`, `ACOS(x)`, `ATAN(x)` | inverse trig |
| `ATAN2(y, x)` | two-arg arctangent |
| `EXP(x)` | natural exponent |
| `LN(x)` | natural log |
| `LG(x)` | common log (base 10) |
| `SQRT(x)` | square root |
| `CEIL(x)`, `FLOOR(x)`, `TRUNC(x)` | rounding |
| `ROUND(x)` | round to nearest |
| `ROUND(x, n)` | round to `n` decimal places |

`IntSwissKnife` / `IntConverter` reject these (raises
[`GenApi.FormulaEvalError`](@ref GenICam.GenApi.FormulaEvalError)) —
the spec forbids float math in the integer evaluator.

## Constants

  * `PI` — `3.141592653589793...`
  * `E`  — `2.718281828459045...`

Float-only. `IntSwissKnife` rejects both.

## Variables

Variables are introduced by `<pVariable>` child elements and bound
to other nodes:

```xml
<IntSwissKnife Name="MaxBufferCount">
    <pVariable Name="ImgSize">PayloadSize</pVariable>
    <Formula>(64 * 1024 * 1024) / ImgSize</Formula>
</IntSwissKnife>
```

When the formula is evaluated, every reference to `ImgSize` triggers a
fresh read of the `PayloadSize` node — recursively, with cycle
detection (a self-referencing chain raises
[`GenApi.CircularDependency`](@ref GenICam.GenApi.CircularDependency)).

In `<Converter>` / `<IntConverter>`, two implicit variables are bound
in addition:

  * `FROM` — bound on read-path. The current register value, before
    `FormulaFrom` runs.
  * `TO` — bound on write-path. The user-supplied value, before
    `FormulaTo` runs.

The spec is clear which goes where, but in practice many vendors
(notably MATRIX VISION) use `TO` in *both* formulas regardless of
direction. `GenICam.jl` handles this pragmatically: in either path,
both `FROM` and `TO` resolve to the same input value. See
[Vendor notes](vendors.md) for the rationale.

## Examples from real cameras

These are taken verbatim from cameras `GenICam.jl` has been tested
against (vendor names redacted):

```xml
<!-- IntSwissKnife: clamp Height to even multiples up to the sensor max -->
<IntSwissKnife Name="HeightClamp">
    <pVariable Name="MAX">SensorHeightMax</pVariable>
    <pVariable Name="REQ">RequestedHeight</pVariable>
    <Formula>(REQ &gt; MAX ? MAX : REQ) &amp; ~1</Formula>
</IntSwissKnife>

<!-- Converter: ExposureTime (microseconds) <-> ExposureTimeRaw (ticks of a 100ns clock) -->
<Converter Name="ExposureTime">
    <pValue>ExposureTimeRaw</pValue>
    <FormulaTo>TO * 10</FormulaTo>
    <FormulaFrom>FROM / 10</FormulaFrom>
</Converter>

<!-- IntConverter with a unit and a representation: Bandwidth in Bps -->
<IntConverter Name="DeviceLinkThroughputBps">
    <pValue>DeviceLinkThroughputRaw</pValue>
    <pVariable Name="MUL">MagicConstant</pVariable>
    <FormulaTo>(TO + MUL - 1) / MUL</FormulaTo>
    <FormulaFrom>FROM * MUL</FormulaFrom>
</IntConverter>

<!-- Trigger-source enum quirk: vendor-specific routing -->
<IntSwissKnife Name="TriggerActivationCode">
    <pVariable Name="MODE">TriggerMode</pVariable>
    <pVariable Name="OL">OvertriggerLatchEnable</pVariable>
    <Formula>(MODE = 1) ? 1 : (OL ? 14 : 0)</Formula>
</IntSwissKnife>

<!-- SwissKnife: max bandwidth before frames start dropping -->
<SwissKnife Name="MaxFrameRate">
    <pVariable Name="W">Width</pVariable>
    <pVariable Name="H">Height</pVariable>
    <pVariable Name="BPP">BytesPerPixel</pVariable>
    <pVariable Name="LINK">LinkSpeed</pVariable>
    <Formula>LINK / (W * H * BPP * 1.05)</Formula>
</SwissKnife>
```

Note the XML-entity escaping: `&gt;` for `>`, `&lt;` for `<`, `&amp;`
for `&`. The parser un-escapes these before tokenising.

## Evaluation model

The Julia evaluator uses a Pratt parser → AST → tree-walking
interpreter. Two entry points share one AST type — the difference is
the eval function:

  * `GenApi.eval_int` for
    `IntSwissKnife` / `IntConverter`. All operations stay in `Int64`,
    `/` is `div` (truncate toward zero), trig/exp/log raise.
  * `GenApi.eval_float` for
    `SwissKnife` / `Converter`. Standard IEEE 754 double-precision.

Compilation happens once, at parse time. Each `<Formula>` /
`<FormulaTo>` / `<FormulaFrom>` becomes a small immutable AST stored
on the formula node. Repeated reads pay only the tree-walk cost; the
tokeniser and parser run zero times after `parse_nodemap` returns.

You can use the evaluator outside the camera context for tests or
exploration:

```julia
using GenICam.GenApi

evaluate_int("(2 + 3) * 4")                                       # 20
evaluate_int("(W * H + 7) / 8", Dict(:W => 640, :H => 480))       # 38400
evaluate_float("SQRT(2 * PI)")                                    # 2.5066...
evaluate_float("(FROM = 1) ? 1 : (OL ? 14 : 0)",
               Dict(:FROM => 1, :OL => 0))                        # 1.0
```

## Errors

  * `GenApi.FormulaParseError` — raised at XML-load time when a
    `<Formula>` is unparseable (mismatched parens, unexpected character,
    ...). Carries the source string and a position pointer.
  * `GenApi.FormulaEvalError` — raised at read/write time for runtime
    issues: divide by zero, using a Float-only function in
    `IntSwissKnife`, undefined variable, etc.
  * `GenApi.CircularDependency` — raised when a chain of `pVariable`
    resolutions revisits a node already on the stack.
