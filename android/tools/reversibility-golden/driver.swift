// Part of android/tools/reversibility-golden.sh. The script splices the
// classifier tables out of iOS/Tests/LogicTests.swift between the two markers
// below, compiles this file with iOS/Page/Models/Reversibility.swift, and
// prints one TSV row per corpus entry:
//   escaped-context <TAB> escaped-cwd-or-<nil> <TAB> LEVEL <TAB> tags|joined <TAB> escaped-reason
// Escapes: \\ \n \r \t and \u{HEX} for every scalar below 0x20 or above 0x7E.
import Foundation

let rvCwd = "/Users/me/proj"
//@@RVTABLE@@
//@@HOOKS@@

func esc(_ s: String) -> String {
    var out = ""
    for u in s.unicodeScalars {
        switch u {
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if u.value < 0x20 || u.value > 0x7E { out += "\\u{" + String(u.value, radix: 16, uppercase: true) + "}" } else { out.unicodeScalars.append(u) }
        }
    }
    return out
}

var corpus: [(String, String?)] = []
for (c, _) in rvTable { corpus.append((c, rvCwd)); corpus.append((c, nil)) }
for h in hookTexts { corpus.append((h, rvCwd)) }

// Hand-picked entry points (LogicTests "Reversibility (hand-picked)").
let hand: [(String, String?)] = [
    ("[Bash] ls", nil), ("[Bash] ls\nList", nil), ("[Bash] echo hi\r\nrm -rf x", nil), ("[Bash] cat <<EOF\nx\nEOF\nrm -rf y", nil),
    ("[Bash] cat <<-EOF\nx\nEOF\nrm -rf y", nil), ("[Bash] ls\nrm -rf y", nil), ("[Bash] ls …", "/Users/me/proj"),
    ("Plan ready for review", nil), ("A subagent is asking for approval\n[Task] x", nil),
    ("One of these is waiting for approval:\n• [Bash] ls\n• [Bash] rm -rf x", nil),
    ("One of these is waiting for approval:\n• [Bash] ls\n• [Read] /etc/hosts", "/Users/me/proj"),
    ("One of these is waiting for approval:", nil), ("", nil), ("   \n  ", nil), ("Claude is waiting for your approval", "/Users/me/proj"),
    ("[Edit] /Users/me/proj/a.swift", "/Users/me/proj"), ("[Edit] /Users/me/proj/a.swift", nil), ("[Edit] a.swift (3 edits)", "/Users/me/proj"),
    ("[Edit] ../a.swift", "/Users/me/proj"), ("[Edit] ~/a.swift", "/Users/me/proj"), ("[Edit] /Users/me/projX/a.swift", "/Users/me/proj"),
    ("[Edit] /Users/me/proj/a.swift", "/Users/me/proj/"), ("[Read] /Users/me/proj/a.swift", "/Users/me/proj"), ("[Read] /etc/hosts", "/Users/me/proj"),
    ("[Read] README.md", nil), ("[Glob] *.swift", nil), ("[Grep] foo", nil), ("[LS] .", nil), ("[WebFetch] https://x.y", nil), ("[Task] x", nil),
    ("[Agent] x", nil), ("[Mystery] x", nil), ("[Bash] (no command)", nil), ("[Bash]", nil), ("[Bash] ", nil), ("Bash] ls", nil), ("[Bash ls", nil),
    ("[Bash] ls [redacted]", nil), ("[Bash] ls\u{0301}", nil), ("[Bash\u{0301}] ls", nil), ("[Bash]\u{0301} ls", nil),
    ("[Bash] rm\u{0301} -rf x", nil), ("[Bash] r\u{0301}m -rf x", nil), ("$\u{0301} ls", nil), ("$ \u{0301}ls", nil), ("[Bash] ls…", nil),
    ("[Bash] ls …\u{0301}", nil), ("[Bash] ls \u{2026}", nil),
]
corpus += hand

// Deterministic fuzz: command pieces glued with separators, plus Unicode oddities.
struct Rng { var s: UInt64
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
}
// RV_SEED / RV_COUNT widen the sweep for a one-off check; the committed golden uses the defaults.
var rng = Rng(s: UInt64(ProcessInfo.processInfo.environment["RV_SEED"] ?? "") ?? 0x9E3779B97F4A7C15)
let progs = ["ls", "cat", "rm", "rmdir", "git", "sudo", "find", "sed", "awk", "xargs", "curl", "wget", "sh", "bash", "zsh", "python3", "python", "node",
              "npm", "npx", "yarn", "pnpm", "bun", "cargo", "make", "swift", "gradle", "./gradlew", "mvn", "docker", "kubectl", "terraform", "tofu", "terragrunt",
              "pulumi", "aws", "gcloud", "az", "gh", "xcodebuild", "dotnet", "rake", "brew", "pip", "pytest", "jest", "eslint", "ruff", "tsc", "swiftlint",
              "go", "dd", "diskutil", "crontab", "ssh", "rsync", "tee", "env", "nohup", "time", "nice", "timeout", "command", "exec", "eval", "source", ".",
              "echo", "printf", "pwd", "cd", "pushd", "head", "tail", "grep", "rg", "fd", "sort", "tree", "jq", "yq", "date", "hostname", "export", "alias",
              "mkdir", "touch", "cp", "mv", "chmod", "kill", "open", "psql", "mysql", "sqlite3", "mkfs.ext4", "/bin/ls", "/usr/bin/env", "./ls", "/tmp/x/ls",
              "unknown-tool", "cloc", "less", "bat", "diff", "file", "base64", "uniq", "xxd", "arch", "bundle", "ninja", "just", "task", "cdk", "helm", "fly"]
let words = ["-la", "-rf", "-f", "-r", "-n", "-i", "-e", "-c", "-C", "-p", "-o", "-v", "-q", "-u", "--force", "--hard", "--delete", "--check", "--fix", "--version",
             "--output=x", "--out", "--exec", "--pager=less", "--config=/tmp/x", "--prefix", "/tmp/x", "~/x", "../x", "./x", "x.txt", "src", ".", "--", "-", "-m",
             "status", "log", "diff", "show", "push", "pull", "reset", "clean", "checkout", "branch", "tag", "stash", "drop", "restore", "config", "list", "get",
             "test", "build", "run", "install", "publish", "deploy", "destroy", "apply", "plan", "up", "down", "prune", "delete", "describe", "logs", "ps",
             "origin", "main", "HEAD~1", "-D", "+main", ":main", "-delete", "-exec", "-print", ";", "+", "\\;", "{}", "'rm -rf x'", "\"rm x\"", "$(rm x)", "`rm x`",
             "FOO=bar", "LANG=C", "CC=/tmp/x", "LD_PRELOAD=x", "PATH=/x", "s/a/b/", "p", "'s/a/b/w x'", "-n 5p", "{print $1}", "{system(\"x\")}", "x > y",
             "-j4", "-j", "4", "--jobs=4", "-f Makefile", "all", "tests", "lint", "typecheck", "--noEmit", "pytest", "unittest", "--cov-report=html", "-pfoo",
             "DROP TABLE x", "delete from t", "truncate table t", "ls -la", "sub", "--dry-run", "-X", "-Xswiftc", "-Zfoo", "-Cfoo", "-sfoo", "-H x", "-s x"]
let seps = [" ", " ", " ", " ; ", " && ", " || ", " | ", "\n", "\r\n", " & ", " |& ", " > out.txt ", " >> out ", " 2>&1 ", " > /dev/null ", " 2> /dev/null ", " < in ", " <<EOF\nbody\nEOF\n ", " <<'EOF'\nrm -rf z\nEOF\n"]
let marks: [String] = ["", "", "", "\u{0301}", "\u{200B}", "\u{00A0}", "\u{2028}", "\u{85}", "\u{FF0F}", "\u{1F468}\u{200D}\u{1F469}", "é", "e\u{0301}", "İ", "ß", "\u{FEFF}"]
func cmdLine() -> String {
    var s = ""
    let parts = Int(rng.next() % 4) + 1
    for p in 0..<parts {
        if p > 0 { s += rng.pick(seps) }
        if rng.next() % 6 == 0 { s += rng.pick(["FOO=bar ", "LANG=C ", "sudo ", "env ", "nohup ", "time ", "! ", "( ", "{ ", "if ", "then "]) }
        s += rng.pick(progs)
        let nw = Int(rng.next() % 5)
        for _ in 0..<nw { s += " " + rng.pick(words) }
        if rng.next() % 9 == 0 { s += rng.pick(marks) }
        if rng.next() % 12 == 0 { s += " $(" + rng.pick(progs) + " " + rng.pick(words) + ")" }
        if rng.next() % 14 == 0 { s += " `" + rng.pick(progs) + "`" }
    }
    return s
}
let heads = ["[Bash] ", "[Bash] ", "[Bash] ", "$ ", "[Bash]  ", " [Bash] ", "[Bash]\t"]
let tails = ["", "", "", "\nList files", "\n# desc", "\nrm -rf y", " …", "…", "\n\n— recent activity —\n[Bash] ls", "\n[redacted]", " [redacted]", "\r\nLs"]
let cwds: [String?] = [nil, rvCwd, rvCwd, "/", "/Users/me/proj/"]
for _ in 0..<(Int(ProcessInfo.processInfo.environment["RV_COUNT"] ?? "") ?? 3000) {
    let h = rng.pick(heads)
    var body = cmdLine()
    if rng.next() % 11 == 0 { body += rng.pick(marks) }
    var text = h + body + rng.pick(tails)
    if rng.next() % 40 == 0 { text = "One of these is waiting for approval:\n• [Bash] " + cmdLine() + "\n• [Bash] " + cmdLine() }
    if rng.next() % 60 == 0 { text += String(repeating: "x", count: 1400 + Int(rng.next() % 160)) }
    corpus.append((text, rng.pick(cwds)))
}
// Edits, reads and other tools with odd paths.
let tools = ["Edit", "MultiEdit", "Write", "NotebookEdit", "Read", "Glob", "Grep", "LS", "NotebookRead", "WebFetch", "Task"]
let paths = ["/Users/me/proj/a.swift", "/Users/me/proj", "/Users/me/projX/a", "/Users/me/proj/../x", "a/b.swift", "../a", "~/a", "/etc/hosts", "?", "", " a ", "a (3 edits)", "/Users/me/proj/a (2 edits)", "./a", "/Users/me/proj/é", "a\u{0301}"]
for t in tools { for p in paths { for c in cwds { corpus.append(("[\(t)] \(p)", c)) } } }

for (ctx, cwd) in corpus {
    let v = Reversibility.classify(context: ctx, cwd: cwd)
    let lvl = ["UNDOABLE", "CONSIDERED", "IRREVERSIBLE"][v.level.rawValue]
    print([esc(ctx), cwd.map(esc) ?? "<nil>", lvl, v.tags.map { $0.rawValue }.joined(separator: "|"), esc(v.reason)].joined(separator: "\t"))
}
