using Test
using GenICam
using GenICam.GenApi
using GenICam.GenApi: parse_formula, evaluate_int, evaluate_float,
    eval_int, eval_float, EvalContext, FormulaParseError, FormulaEvalError,
    NumLitInt, NumLitFloat, VarRef, Unary, Binary, Ternary, Call, FormulaAST

@testset "GenApi.formula: tokenizer (via parser smoke)" begin
    # Numbers
    @test evaluate_int("0") == 0
    @test evaluate_int("42") == 42
    @test evaluate_int("0xFF") == 255
    @test evaluate_int("0x10000") == 65536
    @test evaluate_float("1.5") == 1.5
    @test evaluate_float("1.5e2") == 150.0
    @test evaluate_float("1.5E-3") ≈ 0.0015
    # Identifiers
    @test evaluate_int("A", Dict(:A => 7)) == 7
    @test evaluate_int("foo_bar123", Dict(:foo_bar123 => 9)) == 9
end

@testset "GenApi.formula: arithmetic operators" begin
    @test evaluate_int("1 + 2") == 3
    @test evaluate_int("10 - 3") == 7
    @test evaluate_int("4 * 5") == 20
    @test evaluate_int("10 / 3") == 3              # integer division
    @test evaluate_int("10 % 3") == 1
    @test evaluate_int("2 ** 10") == 1024
    @test evaluate_int("-5") == -5
    @test evaluate_int("--5") == 5                  # unary minus twice
    @test evaluate_int("+7") == 7                   # unary plus is no-op

    @test evaluate_float("1.0 / 4.0") == 0.25
    @test evaluate_float("2.0 ** 0.5") ≈ sqrt(2.0)
end

@testset "GenApi.formula: bitwise operators" begin
    @test evaluate_int("0xFF & 0x0F") == 0x0F
    @test evaluate_int("0x0F | 0xF0") == 0xFF
    @test evaluate_int("0xFF ^ 0x0F") == 0xF0
    @test evaluate_int("~0") == -1
    @test evaluate_int("1 << 8") == 256
    @test evaluate_int("256 >> 2") == 64
end

@testset "GenApi.formula: comparison and logical operators" begin
    @test evaluate_int("3 < 5") == 1
    @test evaluate_int("3 > 5") == 0
    @test evaluate_int("3 <= 3") == 1
    @test evaluate_int("3 >= 4") == 0
    @test evaluate_int("3 == 3") == 1
    @test evaluate_int("3 = 3") == 1                # GenApi spelling
    @test evaluate_int("3 != 4") == 1
    @test evaluate_int("3 <> 4") == 1               # GenApi spelling

    @test evaluate_int("1 && 1") == 1
    @test evaluate_int("1 && 0") == 0
    @test evaluate_int("0 || 1") == 1
    @test evaluate_int("0 || 0") == 0
    @test evaluate_int("!0") == 1
    @test evaluate_int("!5") == 0
end

@testset "GenApi.formula: precedence" begin
    # multiplication binds tighter than addition
    @test evaluate_int("2 + 3 * 4") == 14
    @test evaluate_int("(2 + 3) * 4") == 20
    # power right-associative
    @test evaluate_int("2 ** 3 ** 2") == 512        # 2^(3^2) = 2^9
    # bitwise vs comparison
    @test evaluate_int("(1 | 2) == 3") == 1
    # ternary lowest
    @test evaluate_int("1 + 2 < 4 ? 10 : 20") == 10
    # shift between bitwise-and and additive
    @test evaluate_int("1 + 2 << 3") == 24          # (1+2) << 3
    # bitwise & vs ==
    @test evaluate_int("0xFF & 0x0F == 15") == 1
end

@testset "GenApi.formula: ternary nested" begin
    @test evaluate_int("1 ? 2 ? 3 : 4 : 5") == 3
    @test evaluate_int("1 ? 0 ? 3 : 4 : 5") == 4
    @test evaluate_int("0 ? 1 : 2 ? 3 : 4") == 3
    @test evaluate_int("0 ? 1 : 0 ? 3 : 4") == 4
end

@testset "GenApi.formula: SwissKnife built-in functions" begin
    @test evaluate_float("ABS(-3.5)") == 3.5
    @test evaluate_float("SGN(-2.0)") == -1.0
    @test evaluate_float("SGN(0.0)") == 0.0
    @test evaluate_float("SGN(2.0)") == 1.0
    @test evaluate_float("NEG(5.0)") == -5.0
    @test evaluate_float("CEIL(1.2)") == 2.0
    @test evaluate_float("FLOOR(1.8)") == 1.0
    @test evaluate_float("ROUND(1.5)") == 2.0
    @test evaluate_float("TRUNC(-1.7)") == -1.0
    @test evaluate_float("SQRT(9.0)") == 3.0
    @test evaluate_float("EXP(0.0)") == 1.0
    @test evaluate_float("LN(1.0)") == 0.0
    @test evaluate_float("LG(100.0)") == 2.0
    @test evaluate_float("SIN(0.0)") == 0.0
    @test evaluate_float("COS(0.0)") == 1.0
    @test evaluate_float("TAN(0.0)") == 0.0
    @test evaluate_float("ASIN(0.0)") == 0.0
    @test evaluate_float("ACOS(1.0)") == 0.0
    @test evaluate_float("ATAN(0.0)") == 0.0
    @test evaluate_float("ATAN2(1.0, 1.0)") ≈ pi/4
    @test evaluate_float("ROUND(1.2345, 2)") == 1.23
end

@testset "GenApi.formula: SwissKnife constants PI and E" begin
    @test evaluate_float("PI") ≈ pi
    @test evaluate_float("E") ≈ MathConstants.e
    @test evaluate_float("2 * PI") ≈ 2pi
    @test evaluate_float("SIN(PI/2)") ≈ 1.0
end

@testset "GenApi.formula: IntSwissKnife restrictions" begin
    # Allowed
    @test evaluate_int("ABS(-7)") == 7
    @test evaluate_int("SGN(-2)") == -1
    @test evaluate_int("NEG(5)") == -5
    # IntSwissKnife forbids trig/exp
    @test_throws FormulaEvalError evaluate_int("SIN(0)")
    @test_throws FormulaEvalError evaluate_int("SQRT(4)")
    @test_throws FormulaEvalError evaluate_int("PI")
    @test_throws FormulaEvalError evaluate_int("E")
end

@testset "GenApi.formula: variable references and FROM/TO" begin
    @test evaluate_float("FROM / 8000.0", Dict(:FROM => 16000.0)) == 2.0
    @test evaluate_float("TO * 8000.0", Dict(:TO => 0.5)) == 4000.0
    @test evaluate_int("(TO + 999) / 1000", Dict(:TO => 1500)) == 2
    # Real FLIR-style trigger formula
    @test evaluate_int("(FROM = 1) ? 1 : (OL ? 14 : 0)",
                       Dict(:FROM => 1, :OL => 0)) == 1
    @test evaluate_int("(FROM = 1) ? 1 : (OL ? 14 : 0)",
                       Dict(:FROM => 0, :OL => 1)) == 14
    @test evaluate_int("(FROM = 1) ? 1 : (OL ? 14 : 0)",
                       Dict(:FROM => 0, :OL => 0)) == 0
end

@testset "GenApi.formula: integer truncation semantics" begin
    # IntSwissKnife uses div() — truncation toward zero, matching the
    # reference C++ implementation's `int64 / int64`.
    @test evaluate_int("3 / 2") == 1
    @test evaluate_int("-3 / 2") == -1          # truncate toward zero
    @test evaluate_int("7 % 3") == 1
end

@testset "GenApi.formula: parse errors" begin
    @test_throws FormulaParseError parse_formula("")
    @test_throws FormulaParseError parse_formula("(")
    @test_throws FormulaParseError parse_formula("1 +")
    @test_throws FormulaParseError parse_formula("0xZZ")
    @test_throws FormulaParseError parse_formula("1 ? 2")     # missing :
    @test_throws FormulaParseError parse_formula("@")
    @test_throws FormulaParseError parse_formula("1 2")       # juxtaposition
end

@testset "GenApi.formula: eval errors" begin
    @test_throws FormulaEvalError evaluate_int("1 / 0")
    @test_throws FormulaEvalError evaluate_int("1 % 0")
    @test_throws FormulaEvalError evaluate_int("UNDEF")
    @test_throws FormulaEvalError evaluate_float("UNDEF")
    @test_throws FormulaEvalError evaluate_float("UNKNOWN_FUNC(1.0)")
end

@testset "GenApi.formula: AST stability under repeat eval" begin
    # parse once, eval many — verifies no global state leaks between calls
    ast = parse_formula("(A * 2) + 1")
    for v in 0:5
        @test eval_int(ast, EvalContext(Dict{Symbol,Real}(:A => v))) == 2v + 1
    end
end

@testset "GenApi.formula: short-circuit evaluation" begin
    # If LHS of && is 0, RHS is not evaluated. Use a callback that throws
    # to confirm the RHS variable is never looked up.
    side_effect = Ref(false)
    ctx = EvalContext(name -> begin
        if name === :A; return 0
        elseif name === :B; side_effect[] = true; return 99
        else; throw(FormulaEvalError("nope"))
        end
    end)
    ast = parse_formula("A && B")
    @test eval_int(ast, ctx) == 0
    @test side_effect[] == false

    # If LHS of || is 1, RHS is not evaluated.
    side_effect[] = false
    ctx2 = EvalContext(name -> begin
        if name === :A; return 1
        elseif name === :B; side_effect[] = true; return 99
        else; throw(FormulaEvalError("nope"))
        end
    end)
    ast2 = parse_formula("A || B")
    @test eval_int(ast2, ctx2) == 1
    @test side_effect[] == false
end
