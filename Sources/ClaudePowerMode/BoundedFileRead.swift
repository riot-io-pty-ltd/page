import Foundation

/// Reads a small file whose path comes from somewhere Page doesn't control
/// (a project's `.claude/settings.json`, a `--settings` argument).
///
/// A size check on the path followed by `FileManager.contents(atPath:)` is
/// not a bound: the path can be a symlink to `/dev/zero`, a FIFO that never
/// delivers EOF (hanging the caller's queue), or a file swapped between the
/// check and the read. So: refuse `/dev/` paths, open non-blocking, check on
/// the opened descriptor that it is a regular file, and read at most
/// `maxBytes` from that descriptor. Any failure returns nil.
enum BoundedFileRead {
    static let defaultMaxBytes = 1 << 20

    static func read(_ path: String, maxBytes: Int = defaultMaxBytes) -> Data? {
        // Checked on the literal path before any filesystem call: even a
        // stat inside a protected folder can raise a privacy prompt.
        guard !path.hasPrefix("/dev/"), !PrivacyProtectedPaths.contains(path) else { return nil }
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard !resolved.hasPrefix("/dev/"), !PrivacyProtectedPaths.contains(resolved) else { return nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= off_t(maxBytes) else { return nil }
        guard let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes else { return nil }
        return data
    }

    /// The last `maxBytes` of a file whose path comes from elsewhere (a
    /// transcript or rollout the phone is shown), with the same guards as
    /// `read`: no `/dev/`, nothing in a privacy-protected folder, a regular
    /// file checked on the opened descriptor, and never more than
    /// `maxBytes` read. `offset` is where the returned bytes start in the
    /// file, `truncated` whether anything comes before them.
    static func tail(_ path: String, maxBytes: Int) -> (data: Data, offset: UInt64, truncated: Bool)? {
        guard maxBytes > 0, !path.hasPrefix("/dev/"), !PrivacyProtectedPaths.contains(path) else { return nil }
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard !resolved.hasPrefix("/dev/"), !PrivacyProtectedPaths.contains(resolved) else { return nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= 0 else { return nil }
        let size = UInt64(st.st_size)
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        let data: Data
        do {
            try handle.seek(toOffset: offset)
            data = try handle.read(upToCount: maxBytes) ?? Data()   // nil at EOF
        } catch {
            return nil
        }
        return (data, offset, offset > 0)
    }
}

/// Folders macOS guards behind a per-app privacy prompt (Desktop,
/// Documents, Downloads, iCloud Drive and other cloud storage, removable
/// and network volumes). Opening a file there from Page blocks the calling
/// thread until someone answers "Page would like to access files in your
/// Documents folder" — which froze the tick queue, and with it keep-awake,
/// when a Claude session ran in ~/Documents. Page never reads there; a
/// caller that needed the file treats it as unreadable.
enum PrivacyProtectedPaths {
    static func contains(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let p = path == "~" ? home : path.hasPrefix("~/") ? (home as NSString).appendingPathComponent(String(path.dropFirst(2))) : path
        let protectedUnderHome = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music",
                                  "Library/Mobile Documents", "Library/CloudStorage"]
        for sub in protectedUnderHome {
            let dir = (home as NSString).appendingPathComponent(sub)
            if p == dir || p.hasPrefix(dir + "/") { return true }
        }
        return p.hasPrefix("/Volumes/")
    }
}
