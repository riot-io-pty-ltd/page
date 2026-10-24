import AppKit

// Must run before anything can spawn a child: writing to a pipe whose reader
// died (e.g. a crashed `codex app-server`) raises SIGPIPE, whose default
// action kills the whole menu-bar app — and Claude paging with it. Ignored,
// the write fails with EPIPE and the caller's error handling runs instead.
signal(SIGPIPE, SIG_IGN)

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
