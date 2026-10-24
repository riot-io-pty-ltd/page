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
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard !path.hasPrefix("/dev/"), !resolved.hasPrefix("/dev/") else { return nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= off_t(maxBytes) else { return nil }
        guard let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes else { return nil }
        return data
    }
}
