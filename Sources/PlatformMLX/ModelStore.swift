import CommonCrypto
import Foundation
import HuggingFace
import PlatformCore

/// Governed on-disk model artifact store under `<runtime root>/models`.
///
/// Acquisition is explicit only: `pull` runs from the `model pull` CLI command
/// (or tests), never implicitly on inference, never triggered by model output.
/// Downloads land in a `.staging-*` sibling directory, are verified against a
/// manifest (path list + sizes + LFS sha256), and only then renamed into
/// place. A directory without a complete manifest is never treated as ready.
///
/// Layout:
///   models/<dirName>/            - a complete, validated snapshot
///   models/<dirName>/manifest.json
///   models/.staging-<dirName>/   - in-flight pull, renamed on success
///
/// `dirName` is derived deterministically from repo+revision so registry
/// entries never carry filesystem paths.
public final class ModelStore: @unchecked Sendable {
    public static let manifestName = "manifest.json"
    private static let stagingPrefix = ".staging-"

    public let modelsDir: URL

    public init(modelsDir: URL) {
        self.modelsDir = modelsDir
    }

    public convenience init(root: RuntimeRoot) {
        self.init(modelsDir: root.url.appendingPathComponent("models", isDirectory: true))
    }

    /// Deterministic directory name for a repo+revision. Path-safe by
    /// construction (registry validation already bounded the inputs).
    public static func dirName(repo: String, revision: String) -> String {
        let repoPart = repo.replacingOccurrences(of: "/", with: "--")
        let revPart = revision.replacingOccurrences(of: "/", with: "-")
        return "\(repoPart)__\(revPart)"
    }

    public func directory(for source: ModelSource) -> URL {
        modelsDir.appendingPathComponent(Self.dirName(repo: source.repo, revision: source.revision),
                                         isDirectory: true)
    }

    /// Manifest recorded at pull time. `sha256` is the HF LFS object id when
    /// present (a content hash), `oid` is the git blob id otherwise.
    public struct Manifest: Codable, Sendable {
        public var schemaVersion: Int
        public var repo: String
        public var revision: String
        public var resolvedRevision: String?
        public var pulledAt: Double
        public var files: [FileEntry]

        public struct FileEntry: Codable, Sendable {
            public var path: String
            public var size: Int64
            public var sha256: String?
            public var oid: String?
        }
    }

    public struct InstalledModel: Sendable {
        public let dirName: String
        public let manifest: Manifest
    }

    // MARK: - Inspection

    /// Cheap readiness probe for status surfaces: a manifest that parses,
    /// matches the requested source, and whose listed files all exist as
    /// regular, non-symlink files with matching sizes. Hash verification
    /// happens once at pull time; this check is stat-only.
    public func isReady(source: ModelSource) -> Bool {
        (try? validatedDirectory(for: source)) != nil
    }

    /// True when any complete manifest exists under the store.
    public var hasReadyArtifact: Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path)
        else { return false }
        return names.contains { name in
            !name.hasPrefix(".") && !name.hasPrefix(Self.stagingPrefix)
                && (try? validatedManifest(dirName: name)) != nil
        }
    }

    /// Returns the model directory when the artifact for `source` is complete
    /// and valid; throws providerUnavailable otherwise (missing, staged,
    /// tampered). All filesystem assumptions are rechecked here.
    public func validatedDirectory(for source: ModelSource) throws -> URL {
        let dir = directory(for: source)
        let manifest = try validatedManifest(dirName: dir.lastPathComponent)
        guard manifest.repo == source.repo, manifest.revision == source.revision else {
            throw PlatformError(.providerUnavailable, detail: "model manifest mismatch")
        }
        return dir
    }

    private func validatedManifest(dirName: String) throws -> Manifest {
        let dir = modelsDir.appendingPathComponent(dirName, isDirectory: true)
        guard !isSymlink(dir) else { throw PlatformError(.rootUnsafe, detail: "model dir symlink") }
        let manifestURL = dir.appendingPathComponent(Self.manifestName)
        guard let data = FileManager.default.contents(atPath: manifestURL.path),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.schemaVersion == 1 else {
            throw PlatformError(.providerUnavailable, detail: "model artifact not pulled")
        }
        for file in manifest.files {
            guard Self.isSafeRelativePath(file.path) else {
                throw PlatformError(.rootUnsafe, detail: "manifest path unsafe")
            }
            let url = dir.appendingPathComponent(file.path)
            guard !isSymlink(url) else {
                throw PlatformError(.rootUnsafe, detail: "model file symlink")
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  !isDir.boolValue else {
                throw PlatformError(.providerUnavailable, detail: "model file missing")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size])
                as? Int64
            guard size == file.size else {
                throw PlatformError(.providerUnavailable, detail: "model file size mismatch")
            }
        }
        return manifest
    }

    public func list() -> [InstalledModel] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path)
        else { return [] }
        return names.sorted().compactMap { name in
            guard !name.hasPrefix("."), !name.hasPrefix(Self.stagingPrefix),
                  let manifest = try? validatedManifest(dirName: name) else { return nil }
            return InstalledModel(dirName: name, manifest: manifest)
        }
    }

    public func remove(source: ModelSource) throws {
        let dir = directory(for: source)
        guard !isSymlink(dir) else { throw PlatformError(.rootUnsafe, detail: "model dir symlink") }
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw PlatformError(.notFound, detail: "model not pulled")
        }
        try FileManager.default.removeItem(at: dir)
    }

    // MARK: - Pull

    /// Downloads a pinned repo snapshot into the store. Runs entirely inside
    /// the staging directory; on success verifies every file's size (and the
    /// LFS sha256 when the hub reports one), writes the manifest, then renames
    /// into place. A failed or interrupted pull leaves only staging debris,
    /// which the next pull replaces; the store never exposes it as ready.
    public func pull(source: ModelSource,
                     progress: (@Sendable (Double) -> Void)? = nil) async throws -> Manifest {
        let dirName = Self.dirName(repo: source.repo, revision: source.revision)
        let staging = modelsDir.appendingPathComponent(Self.stagingPrefix + dirName,
                                                       isDirectory: true)
        let final = modelsDir.appendingPathComponent(dirName, isDirectory: true)
        let fm = FileManager.default

        guard let repoID = Repo.ID(rawValue: source.repo) else {
            throw PlatformError(.invalidRequest, detail: "bad repo id")
        }
        try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: staging.path) {
            try fm.removeItem(at: staging)
        }
        // mkdir, not createDirectory: it must fail if the staging path already
        // exists so two concurrent pulls of the same model refuse rather than
        // interleave files.
        guard mkdir(staging.path, 0o700) == 0 else {
            throw PlatformError(.conflict, detail: "pull already in progress")
        }

        do {
            let hub = HubClient(host: HubClient.defaultHost,
                                tokenProvider: .none,
                                cache: nil)
            // Enumerate first: the manifest is the contract the download is
            // verified against.
            let tree = try await hub.listFiles(in: repoID, revision: source.revision)
            let wanted = tree.filter { entry in
                entry.type == .file && Self.isSafeRelativePath(entry.path)
            }
            guard !wanted.isEmpty else {
                throw PlatformError(.notFound, detail: "repo has no files")
            }
            let entries: [Manifest.FileEntry] = wanted.map { entry in
                Manifest.FileEntry(path: entry.path,
                                   size: Int64(entry.effectiveSize ?? -1),
                                   sha256: entry.lfs?.oid,
                                   oid: entry.oid)
            }
            guard entries.allSatisfy({ $0.size >= 0 }) else {
                throw PlatformError(.internal, detail: "repo listed unsized files")
            }

            // Resolve the pinned commit for the record.
            let headFile = try? await hub.getFile(at: "config.json", in: repoID,
                                                  revision: source.revision)

            // Per-file downloads straight into staging - no HF cache, so no
            // doubled disk usage and no foreign directory structure inside
            // the managed root. Progress is aggregated by bytes.
            let totalBytes = entries.reduce(Int64(0)) { $0 + $1.size }
            let completed = ProgressBox()
            for entry in wanted {
                let fileProgress = Progress(totalUnitCount: max(entry.effectiveSize.map(Int64.init) ?? 1, 1))
                let destination = staging.appendingPathComponent(entry.path)
                try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                let watcher = ProgressWatcher(
                    fileProgress: fileProgress,
                    onChange: {
                        progress?(Double(completed.value + fileProgress.completedUnitCount)
                                  / Double(max(totalBytes, 1)))
                    })
                watcher.start()
                do {
                    _ = try await hub.downloadFile(
                        at: entry.path, from: repoID, to: destination,
                        revision: source.revision, progress: fileProgress,
                        transport: .lfs)
                } catch {
                    watcher.stop()
                    throw error
                }
                watcher.stop()
                completed.add(fileProgress.totalUnitCount)
                progress?(Double(completed.value) / Double(max(totalBytes, 1)))
            }

            // Post-download verification: every manifest path present, right
            // size, LFS sha256 exact.
            for i in entries.indices {
                let url = staging.appendingPathComponent(entries[i].path)
                guard !isSymlink(url),
                      let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int64,
                      size == entries[i].size else {
                    throw PlatformError(.storageFailure,
                                        detail: "downloaded file failed verification")
                }
                if let expected = entries[i].sha256 {
                    let digest = try Self.sha256(of: url)
                    guard digest == expected else {
                        throw PlatformError(.storageFailure,
                                            detail: "downloaded file hash mismatch")
                    }
                }
            }

            let manifest = Manifest(
                schemaVersion: 1, repo: source.repo, revision: source.revision,
                resolvedRevision: headFile?.revision,
                pulledAt: Date().timeIntervalSince1970, files: entries)
            let manifestURL = staging.appendingPathComponent(Self.manifestName)
            try JSONEncoder.sorted.encode(manifest).write(to: manifestURL)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)

            if fm.fileExists(atPath: final.path) {
                try fm.removeItem(at: final)
            }
            try fm.moveItem(at: staging, to: final)
            return manifest
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    // MARK: - Helpers

    private func isSymlink(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// Manifest/download paths must stay inside the model directory: relative,
    /// no empty components, no `.`/`..`, no leading or trailing slash.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"),
              path.utf8.allSatisfy({ $0 != 0 }) else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0 == "." || $0 == ".." || $0.isEmpty }
    }

    /// Aggregate completed-bytes counter for pull progress.
    private final class ProgressBox: @unchecked Sendable {
        private var _value: Int64 = 0
        private let lock = NSLock()
        var value: Int64 { lock.lock(); defer { lock.unlock() }; return _value }
        func add(_ delta: Int64) { lock.lock(); _value += delta; lock.unlock() }
    }

    /// KVO bridge from a per-file `Progress` object to the aggregate callback.
    private final class ProgressWatcher: NSObject {
        private let fileProgress: Progress
        private let onChange: @Sendable () -> Void
        private var observation: NSKeyValueObservation?

        init(fileProgress: Progress, onChange: @escaping @Sendable () -> Void) {
            self.fileProgress = fileProgress
            self.onChange = onChange
        }

        func start() {
            observation = fileProgress.observe(\.completedUnitCount) { [onChange] _, _ in
                onChange()
            }
        }

        func stop() { observation = nil }
    }

    private static func sha256(of url: URL) throws -> String {
        var ctx = CC_SHA256_CTX()
        CC_SHA256_Init(&ctx)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            chunk.withUnsafeBytes { ptr in
                _ = CC_SHA256_Update(&ctx, ptr.baseAddress, CC_LONG(ptr.count))
            }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &ctx)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSONEncoder {
    static let sorted: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}
