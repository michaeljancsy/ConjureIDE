//
//  CompileIPC.swift
//  Shared
//
//  File-based IPC so the AU extension can ask the Terminal companion app to
//  run rustc. Required because the AU sandbox blocks Process.run() on any
//  binary outside the extension's own signed bundle — after Phase 3e strips
//  bundled rustc, the Terminal (non-sandboxed) is the only process that can
//  execute rustc from the App Group LanguageModules path.
//
//  Wire format (mirrors LanguageModuleIPC):
//    <AppGroup>/compile-request.json  — extension writes, Terminal reads
//    <AppGroup>/compile-result.json   — Terminal writes, extension reads
//    <AppGroup>/compile-output/<requestId>.wasm — Terminal writes, extension reads + deletes
//

import Foundation

struct CompileRequest: Codable {
    /// UUID the extension generates per compile; the result file must carry
    /// the same ID so the polling extension knows it's for this request.
    let requestId: String
    /// Source language ("rust" for now; future Lua / C++ share this channel).
    let language: String
    /// Full source text to compile.
    let source: String
    /// Path to the conjuredsp rlib the extension wants linked (usually
    /// <module>/lib/libconjuredsp.rlib). Nil for languages that don't use it.
    let conjuredspRlibPath: String?
    /// Directory to add via `-L dependency=` for user-installed crates.
    /// Nil when no user crates are installed.
    let cratesLibPath: String?
    /// `[(crateName, rlibPath)]` pairs for user-installed crates. Added as
    /// `--extern name=path`. Empty when no user crates are installed.
    let externs: [CompileExtern]
    /// Monotonic wall-clock timestamp so old orphaned requests can be aged out.
    let timestamp: TimeInterval
}

struct CompileExtern: Codable {
    let name: String
    let path: String
}

struct CompileResult: Codable {
    let requestId: String
    let success: Bool
    /// Path to the produced WASM file when `success` is true. The extension
    /// must read and delete it.
    let wasmPath: String?
    /// Short human error message when `success` is false.
    let errorMessage: String?
    /// Full stderr from rustc when the compile itself failed — surfaces into
    /// the editor's Problems panel.
    let stderr: String?
    let timestamp: TimeInterval
}

enum CompileIPC {
    static let requestFile = "compile-request.json"
    static let resultFile = "compile-result.json"
    static let outputDirectory = "compile-output"

    /// Absolute timeout for the extension's poll loop. rustc compiles are
    /// usually <5s but worst-case (proc-macro deps) can reach ~60s.
    static let pollTimeoutSeconds: TimeInterval = 120
}
