import Foundation

/// Owns filesystem safety for the runtime root: creation, permission modes,
/// symlink refusal, ownership checks, and the exclusive lifetime lock.
public final class RuntimeRoot: @unchecked Sendable {
    public let url: URL
    private var lockFD: Int32 = -1

    /// Names the platform itself is allowed to create. Anything else in a
    /// non-empty root means the directory is not ours.
    private static let ownedNames: Set<String> = [
        "config.json", "registry.json", "state.sqlite3",
        "state.sqlite3-wal", "state.sqlite3-shm",
        "lock.fd", "daemon.json", "sessions", "models",
    ]

    public init(url: URL) {
        // Canonicalize only the deepest existing ancestor, keeping the final
        // component literal. standardizedFileURL resolves symlinks only for
        // components that exist at call time, so its result changes once the
        // root is created - the Keychain key and lock path must not depend on
        // whether credential or serve ran first.
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let name = url.lastPathComponent
        self.url = name.isEmpty ? url.standardizedFileURL
                                : parent.appendingPathComponent(name, isDirectory: true)
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ondevice-agent-platform", isDirectory: true)
    }

    public var configURL: URL { url.appendingPathComponent("config.json") }
    public var registryURL: URL { url.appendingPathComponent("registry.json") }
    public var databaseURL: URL { url.appendingPathComponent("state.sqlite3") }
    public var lockURL: URL { url.appendingPathComponent("lock.fd") }
    public var daemonURL: URL { url.appendingPathComponent("daemon.json") }

    /// True when a path component at `url` is a symlink; we refuse these.
    private func isSymlink(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// Prepare a fresh or previously created root. Refuses: symlinked root,
    /// roots containing unrelated files, non-owned roots.
    public func prepare() throws {
        let fm = FileManager.default
        if isSymlink(url) { throw PlatformError(.rootUnsafe, detail: "root is symlink") }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw PlatformError(.rootUnsafe, detail: "root not directory") }
            let entries = try fm.contentsOfDirectory(atPath: url.path)
            for name in entries where !RuntimeRoot.ownedNames.contains(name) {
                throw PlatformError(.rootUnsafe, detail: "unrelated entry: present")
            }
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Opens/creates an owned file with O_NOFOLLOW and mode 0600.
    private func openOwned(_ url: URL, flags: Int32) throws -> Int32 {
        if isSymlink(url) { throw PlatformError(.rootUnsafe, detail: "symlinked state file") }
        let fd = open(url.path, flags | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PlatformError(.storageFailure, detail: "open errno \(errno)") }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw PlatformError(.rootUnsafe, detail: "not a regular file")
        }
        if st.st_uid != getuid() { close(fd); throw PlatformError(.rootUnsafe, detail: "not owned") }
        fchmod(fd, 0o600)
        return fd
    }

    /// Acquires the exclusive nonblocking per-root lifetime lock.
    public func acquireLock() throws {
        let fd = try openOwned(lockURL, flags: O_CREAT | O_RDWR)
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            throw PlatformError(.conflict, detail: "root already locked")
        }
        lockFD = fd
    }

    public func releaseLock() {
        if lockFD >= 0 {
            flock(lockFD, LOCK_UN)
            close(lockFD)
            lockFD = -1
        }
    }

    /// Validates a state path before SQLite touches it (db/wal/shm).
    public func checkStateFiles() throws {
        for name in ["state.sqlite3", "state.sqlite3-wal", "state.sqlite3-shm"] {
            let p = url.appendingPathComponent(name)
            if isSymlink(p) { throw PlatformError(.rootUnsafe, detail: "symlinked db file") }
        }
        for name in ["config.json", "registry.json", "daemon.json"] {
            let p = url.appendingPathComponent(name)
            if isSymlink(p) { throw PlatformError(.rootUnsafe, detail: "symlinked config file") }
        }
    }

    /// Writes small JSON metadata files with mode 0600 via openOwned+write.
    public func writeOwnedJSON(_ object: JSONValue, to url: URL) throws {
        let data = try object.encoded()
        let fd = try openOwned(url, flags: O_CREAT | O_WRONLY | O_TRUNC)
        defer { close(fd) }
        try data.withUnsafeBytes { ptr in
            var base = ptr.baseAddress!
            var count = ptr.count
            while count > 0 {
                let n = write(fd, base, count)
                guard n > 0 else { throw PlatformError(.storageFailure, detail: "write errno \(errno)") }
                base += n; count -= n
            }
        }
    }

    public func readOwnedJSON(_ url: URL) throws -> JSONValue? {
        if isSymlink(url) { throw PlatformError(.rootUnsafe, detail: "symlinked file") }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let fd = try openOwned(url, flags: O_RDONLY)
        defer { close(fd) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 { throw PlatformError(.storageFailure, detail: "read errno \(errno)") }
            if n == 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.count > PlatformLimits.requestBodyBytes {
                throw PlatformError(.storageFailure, detail: "file too large")
            }
        }
        return try JSONValue.decode(data)
    }

    /// Nonsecret daemon marker: the bound loopback port the ACP facade reads.
    public func writeDaemonMarker(port: UInt16) throws {
        try writeOwnedJSON(.object(["port": .int(Int64(port))]), to: daemonURL)
    }

    public func readDaemonMarker() throws -> UInt16? {
        guard let value = try readOwnedJSON(daemonURL),
              let port = value.objectValue?["port"]?.intValue,
              port > 0, port <= 65_535 else { return nil }
        return UInt16(port)
    }

    public func removeDaemonMarker() {
        try? FileManager.default.removeItem(at: daemonURL)
    }
}
