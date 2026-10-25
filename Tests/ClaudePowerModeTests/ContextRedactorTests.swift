import XCTest
@testable import ClaudePowerMode

/// Page context leaves the Mac (relay storage, APNs, lock-screen banners),
/// so the detector redacts it the same way the hook does.
final class ContextRedactorTests: XCTestCase {
    typealias R = ContextRedactor
    typealias D = InterventionDetector

    /// Inputs shared with the Python redactor (hooks/page-extract-context.py).
    static let cases: [String] = [
        #"curl -H "Authorization: Bearer sk-live-abcdefghijklmnop1234" https://api.example.com"#,
        "export OPENAI_API_KEY=sk-proj-0123456789abcdefABCDEF",
        "password: hunter2hunter2",
        #"{"client_secret": "s3cr3t-value", "name": "ok"}"#,
        "git clone https://alice:pa55word@github.com/acme/repo.git",
        "token ghp_0123456789abcdefghijABCDEFGHIJ",
        "github_pat_11ABCDEFG0123456789_abcdefghijklmnop",
        "xoxb-123456789012-abcdefABCDEF",
        "aws key AKIAABCDEFGHIJKLMNOP here",
        "maps AIzaSyA0123456789abcdefghijklmnopqrstu",
        "-----BEGIN RSA PRIVATE KEY-----\nMIIEow\nabc\n-----END RSA PRIVATE KEY-----\nafter",
        "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBg (cut short",
        "-----BEGIN PGP PRIVATE KEY BLOCK-----\nlQOYBF\n=AbCd\n-----END PGP PRIVATE KEY BLOCK-----\nafter",
        "Basic dXNlcjpwYXNzd29yZA==",
        "basic configuration of the token parser",
        "npm test -- --watch",
        "café ☕️ DB_PASSWORD='p@ss w0rd' ok",
    ]

    func testMasksSecretsButKeepsTheCommandReadable() {
        XCTAssertEqual(R.redact(Self.cases[0]),
                       #"curl -H "Authorization: Bearer [redacted]" https://api.example.com"#)
        XCTAssertEqual(R.redact("export OPENAI_API_KEY=sk-proj-0123456789abcdefABCDEF"), "export OPENAI_API_KEY=[redacted]")
        XCTAssertEqual(R.redact("git clone https://alice:pa55word@github.com/acme/repo.git"),
                       "git clone https://[redacted]@github.com/acme/repo.git")
        XCTAssertEqual(R.redact("-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBg (cut short"), "[redacted private key]")
        XCTAssertEqual(R.redact("-----BEGIN PGP PRIVATE KEY BLOCK-----\nlQOYBF\n=AbCd\n-----END PGP PRIVATE KEY BLOCK-----\nafter"),
                       "[redacted private key]\nafter")
        XCTAssertEqual(R.redact("basic configuration of the token parser"), "basic configuration of the token parser")
        XCTAssertEqual(R.redact("npm test -- --watch"), "npm test -- --watch")
        for c in Self.cases { XCTAssertEqual(R.redact(R.redact(c)), R.redact(c), "idempotent: \(c)") }
    }

    func testDetectorContextIsRedactedBeforeClipping() {
        let bash = D.describeToolUse(name: "Bash", input: ["command": #"curl -H "Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123""#])
        XCTAssertFalse(bash.contains("abcdefghijklmnop"), bash)
        XCTAssertTrue(bash.hasPrefix("[Bash] curl -H"))
        // A key straddling the Write clip (800) must not leave a fragment.
        let content = String(repeating: "x", count: 790) + " sk-" + String(repeating: "A", count: 40)
        let write = D.describeToolUse(name: "Write", input: ["file_path": "/p/.env", "content": content])
        XCTAssertFalse(write.contains("sk-AAAA"), write)
        let mcp = D.describeToolUse(name: "mcp__db__connect", input: ["password": "correct-horse-battery"])
        XCTAssertFalse(mcp.contains("correct-horse"), mcp)
        var tail = TranscriptTail()
        tail.lastMeaningfulRole = .assistant
        tail.lastAssistantText = "Set GITHUB_TOKEN=ghp_0123456789abcdefghijABCDEFGHIJ and rerun?"
        XCTAssertFalse(D.idleContext(tail).contains("ghp_0123"))
    }

    /// The Swift port must agree with the Python patterns the hook uses.
    func testMatchesThePythonRedactor() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("hooks/page-extract-context.py").path
        let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let python, FileManager.default.fileExists(atPath: script) else {
            throw XCTSkip("python3 or the extractor isn't available")
        }
        for c in Self.cases {
            let r = ProcessRunner.run(python, ["-I", script, "--redact"], timeout: 20, stdin: Data(c.utf8))
            guard r.succeeded else { throw XCTSkip("python3 couldn't run the extractor: \(r.stderr)") }
            XCTAssertEqual(R.redact(c), r.stdout, "case: \(c)")
        }
    }
}
