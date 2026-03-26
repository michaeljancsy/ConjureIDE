import Testing

struct ErrorLineParserTests {

    // MARK: - Python errors

    @Test func pythonSyntaxErrorWithLine() {
        let error = "python_home: /path/to/python\nscript_path: /tmp/process.py\nerror: SyntaxError: expected ':' (line 5)"
        let markers = ErrorLineParser.parse(error, language: .python)
        #expect(markers.count == 1)
        #expect(markers[0].line == 5)
        #expect(markers[0].severity == "error")
        #expect(markers[0].message.contains("SyntaxError"))
    }

    @Test func pythonSyntaxErrorWithLineAndOffset() {
        let error = "python_home: /p\nscript_path: /t\nerror: SyntaxError: invalid syntax (line 3, offset 10)"
        let markers = ErrorLineParser.parse(error, language: .python)
        #expect(markers.count == 1)
        #expect(markers[0].line == 3)
        #expect(markers[0].column == 10)
        #expect(markers[0].severity == "error")
    }

    @Test func pythonRuntimeErrorNoLine() {
        let error = "Python process error: ZeroDivisionError: division by zero"
        let markers = ErrorLineParser.parse(error, language: .python)
        #expect(markers.count == 1)
        #expect(markers[0].line == 1)
        #expect(markers[0].severity == "error")
        #expect(markers[0].message.contains("ZeroDivisionError"))
    }

    @Test func pythonNameError() {
        let error = "python_home: /p\nscript_path: /t\nerror: NameError: name 'foo' is not defined"
        let markers = ErrorLineParser.parse(error, language: .python)
        #expect(markers.count == 1)
        #expect(markers[0].line == 1)
        #expect(markers[0].message.contains("NameError"))
    }

    @Test func pythonTracebackWithLine() {
        let error = "Python process error: File \"<string>\", line 12, in process\nTypeError: unsupported operand"
        let markers = ErrorLineParser.parse(error, language: .python)
        #expect(markers.count == 1)
        #expect(markers[0].line == 12)
    }

    // MARK: - Rust errors

    @Test func rustSingleCompilationError() {
        let error = """
        error[E0308]: mismatched types
         --> dsp.rs:5:10
          |
        5 |     let x: u32 = "hello";
          |            ---   ^^^^^^^ expected `u32`, found `&str`
        """
        let markers = ErrorLineParser.parse(error, language: .rust)
        #expect(markers.count == 1)
        #expect(markers[0].line == 5)
        #expect(markers[0].column == 10)
        #expect(markers[0].severity == "error")
        #expect(markers[0].message.contains("mismatched types"))
    }

    @Test func rustMultipleErrors() {
        let error = """
        error[E0308]: mismatched types
         --> dsp.rs:5:10
          |
        5 |     let x: u32 = "hello";

        error[E0425]: cannot find value `foo`
         --> dsp.rs:12:5
          |
        12|     foo;
        """
        let markers = ErrorLineParser.parse(error, language: .rust)
        #expect(markers.count == 2)
        #expect(markers[0].line == 5)
        #expect(markers[1].line == 12)
        #expect(markers[0].message.contains("mismatched types"))
        #expect(markers[1].message.contains("cannot find value"))
    }

    @Test func rustWarning() {
        let error = """
        warning: unused variable: `x`
         --> dsp.rs:3:9
          |
        3 |     let x = 42;
        """
        let markers = ErrorLineParser.parse(error, language: .rust)
        #expect(markers.count == 1)
        #expect(markers[0].line == 3)
        #expect(markers[0].severity == "warning")
        #expect(markers[0].message.contains("unused variable"))
    }

    @Test func rustMixedErrorsAndWarnings() {
        let error = """
        warning: unused variable: `x`
         --> dsp.rs:3:9

        error[E0308]: mismatched types
         --> dsp.rs:10:5
        """
        let markers = ErrorLineParser.parse(error, language: .rust)
        #expect(markers.count == 2)
        #expect(markers[0].severity == "warning")
        #expect(markers[0].line == 3)
        #expect(markers[1].severity == "error")
        #expect(markers[1].line == 10)
    }

    @Test func wasmLoadErrorNoLine() {
        let error = "Invalid WASM module: validation error at offset 42"
        let markers = ErrorLineParser.parse(error, language: .rust)
        #expect(markers.count == 1)
        #expect(markers[0].line == 1)
        #expect(markers[0].severity == "error")
    }

    @Test func emptyErrorString() {
        let markers = ErrorLineParser.parse("", language: .python)
        #expect(markers.count == 1)
        #expect(markers[0].line == 1)
    }
}
