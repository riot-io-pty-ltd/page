import AppKit

// Must run before anything can spawn a child: writing to a pipe whose reader
// died (e.g. a crashed `codex app-server`) raises SIGPIPE, whose default
// action kills the whole menu-bar app — and Claude paging with it. Ignored,
// the write fails with EPIPE and the caller's error handling runs instead.
signal(SIGPIPE, SIG_IGN)

// `--render-ui <dir>`: draw the new UI with fixture data and exit. Handled
// before AppDelegate exists, so no backend, hook, relay or config code runs.
// The flag is terminal: with or without a directory it never falls through to the app.
if CommandLine.arguments.contains(RenderHarness.flag) {
    guard let dir = RenderHarness.outputDirectory(arguments: CommandLine.arguments) else {
        FileHandle.standardError.write(Data("usage: ClaudePowerMode --render-ui <output-directory>\n".utf8))
        exit(2)
    }
    Task { @MainActor in RenderHarness.run(outputDirectory: dir) }
    dispatchMain()
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
