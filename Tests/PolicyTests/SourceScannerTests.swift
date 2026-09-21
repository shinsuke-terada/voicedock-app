// SourceScanner と CodeTokenizer の固定テスト（T-04）。
import Testing

@Suite("SourceScanner")
struct SourceScannerTests {
    static func code(_ text: String) -> String { SourceScanner.scan(text).codeText }

    @Test("行コメントの中身はコードに残らない")
    func lineCommentIsBlanked() {
        let code = Self.code("let a = 1 // unlink(x)\nlet b = 2\n")
        #expect(!code.contains("unlink"))
        #expect(code.contains("let b = 2"))
    }

    @Test("入れ子のブロックコメントの中身はコードに残らない")
    func nestedBlockCommentIsBlanked() {
        let code = Self.code("/* a /* b */ unlink(x) */ let c = 2\n")
        #expect(!code.contains("unlink"))
        #expect(code.contains("let c = 2"))
    }

    @Test("文字列の中身はコードに残らず、リテラルとして集まる")
    func stringLiteralIsCollected() {
        let scanned = SourceScanner.scan("let s = \"unlink(x)\"\n")
        #expect(!scanned.codeText.contains("unlink"))
        #expect(scanned.literals.map(\.raw) == ["unlink(x)"])
        #expect(scanned.literals.first?.line == 1)
    }

    @Test("エスケープした引用符で文字列が終わらない")
    func escapedQuoteDoesNotCloseString() {
        let scanned = SourceScanner.scan("let s = \"a\\\"b\"\nlet t = 1\n")
        #expect(scanned.literals.map(\.raw) == ["a\\\"b"])
        #expect(scanned.codeText.contains("let t = 1"))
    }

    @Test("文字列補間の中身はコードとして残り、リテラルの raw にもそのまま入る")
    func interpolationStaysInCode() {
        let scanned = SourceScanner.scan("let s = \"x\\(unlink(p))y\"\n")
        #expect(scanned.codeText.contains("unlink(p)"))
        #expect(scanned.literals.map(\.raw) == ["x\\(unlink(p))y"])
    }

    @Test("補間の中の文字列も別のリテラルとして集まる")
    func stringInsideInterpolationIsCollected() {
        let scanned = SourceScanner.scan("let s = \"a\\(\"b\")c\"\n")
        #expect(scanned.literals.map(\.raw) == ["a\\(\"b\")c", "b"])
    }

    @Test("複数行の文字列は 1 つのリテラルで、中の引用符で終わらない")
    func multilineString() {
        let scanned = SourceScanner.scan("let s = \"\"\"\nline1 \"quote\"\n\"\"\"\nlet t = 1\n")
        #expect(scanned.literals.count == 1)
        #expect(scanned.literals.first?.isMultiline == true)
        #expect(scanned.literals.first?.raw == "\nline1 \"quote\"\n")
        #expect(scanned.codeText.contains("let t = 1"))
    }

    @Test("raw 文字列の中の引用符とバックスラッシュは特別扱いしない")
    func rawString() {
        let scanned = SourceScanner.scan("let s = #\"a\"b\\(x)\"#\n")
        #expect(scanned.literals.map(\.raw) == ["a\"b\\(x)"])
        #expect(scanned.literals.first?.hashCount == 1)
        #expect(!scanned.codeText.contains("(x)"))
    }

    @Test("raw 文字列の補間 \\#( はコードとして残る")
    func rawStringInterpolation() {
        let scanned = SourceScanner.scan("let s = #\"a\\#(yy)b\"#\n")
        #expect(scanned.codeText.contains("yy"))
    }

    @Test("行番号が保たれる")
    func lineNumbersArePreserved() {
        let text = "let s = \"\"\"\na\nb\n\"\"\"\nlet z = 1\n"
        let tokens = CodeTokenizer.tokens(SourceScanner.scan(text).code)
        #expect(tokens.first { $0.text == "z" }?.line == 5)
    }

    @Test("#if は文字列として扱わない")
    func compilerDirectiveIsCode() {
        #expect(Self.code("#if DEBUG\nlet a = 1\n#endif\n").contains("#if DEBUG"))
    }

    @Test("閉じていない 1 行の文字列は行末で終わる")
    func unterminatedStringEndsAtLineEnd() {
        let scanned = SourceScanner.scan("let s = \"abc\nlet t = 1\n")
        #expect(scanned.literals.map(\.raw) == ["abc"])
        #expect(scanned.codeText.contains("let t = 1"))
    }

    @Test("トークンは直前の空白の有無を持つ")
    func tokensRecordSpaceBefore() {
        let tokens = CodeTokenizer.tokens(SourceScanner.scan("try! f()\ntry !g()\n").code)
        let bangs = tokens.filter { $0.text == "!" }
        #expect(bangs.map(\.spaceBefore) == [false, true])
    }

    @Test("バッククォートの識別子は中身の名前になる")
    func backtickIdentifier() {
        let tokens = CodeTokenizer.tokens(SourceScanner.scan("let `default` = 1\n").code)
        #expect(tokens.map(\.text) == ["let", "default", "=", "1"])
    }

    @Test("空のソース")
    func emptySource() {
        let scanned = SourceScanner.scan("")
        #expect(scanned.code.isEmpty)
        #expect(scanned.literals.isEmpty)
        #expect(CodeTokenizer.tokens(scanned.code).isEmpty)
    }
}
