import Foundation

/// Reads another (same-user) process's argv and a few allowlisted
/// environment variables via `sysctl(KERN_PROCARGS2)` — the same source
/// `ps -E` uses, no subprocess and no root.
///
/// Privacy: a process's argv and environment routinely hold secrets (API
/// keys, tokens). Only variables in `envKeys` are ever decoded into the
/// result, and callers must derive what they need (a provider, a port, a
/// flag) and drop `argv` — never store, cache or log it.
enum ProcArgs {
    struct Info: Equatable {
        /// Transient: may contain secrets. Derive and discard.
        let argv: [String]
        /// Only allowlisted keys.
        let env: [String: String]
    }

    /// Variables Page reads anywhere. Token-like values among them are only
    /// ever compared against fixed literals by callers.
    static let envAllowlist: Set<String> = [
        "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
        "OLLAMA_HOST",
        "LLAMA_ARG_PORT", "LLAMA_ARG_HOST", "LLAMA_ARG_API_KEY", "LLAMA_ARG_NO_SLOTS",
    ]

    static func read(pid: Int32, envKeys: Set<String> = envAllowlist) -> Info? {
        guard pid > 0 else { return nil }
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mibMax: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mibMax, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        var length = Int(argmax)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let ok = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, 3, raw.baseAddress, &length, nil, 0) == 0
        }
        guard ok, length > 0 else { return nil }
        return parse(Data(buffer.prefix(length)), envKeys: envKeys)
    }

    /// Pure. Layout: int32 argc, the exec path, NUL padding, argc
    /// NUL-terminated argv strings, then NUL-terminated `KEY=value`
    /// environment strings up to an empty string or the end.
    static func parse(_ data: Data, envKeys: Set<String>) -> Info? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let argc = Int(Int32(littleEndian: bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) }))
        guard argc > 0, argc < 100_000 else { return nil }
        var i = 4
        // Exec path.
        while i < bytes.count, bytes[i] != 0 { i += 1 }
        // Padding.
        while i < bytes.count, bytes[i] == 0 { i += 1 }

        func nextString() -> String? {
            guard i < bytes.count else { return nil }
            let start = i
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            let s = String(decoding: bytes[start..<i], as: UTF8.self)
            if i < bytes.count { i += 1 }   // the NUL
            return s
        }

        var argv: [String] = []
        argv.reserveCapacity(argc)
        for _ in 0..<argc {
            guard let s = nextString() else { break }
            argv.append(s)
        }
        guard argv.count == argc else { return nil }

        var env: [String: String] = [:]
        while let s = nextString(), !s.isEmpty {
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = String(s[..<eq])
            if envKeys.contains(key) { env[key] = String(s[s.index(after: eq)...]) }
        }
        return Info(argv: argv, env: env)
    }
}
