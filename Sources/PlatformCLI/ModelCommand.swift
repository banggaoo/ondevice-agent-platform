import Foundation
import PlatformCore
import PlatformMLX

/// `model pull --alias ALIAS | --repo ORG/NAME --revision REV`
/// `model list`
/// `model remove --alias ALIAS`
///
/// Explicit, code-owned artifact management. Pull resolves the declared
/// registry entry (or an explicit repo+revision) and downloads into the
/// managed store with staging + manifest verification. Nothing here runs
/// inference, grants authority, or modifies the registry - declaring a model
/// is a separate act from pulling it, and both are owner-initiated.
enum ModelCommand {
    static func run(args: [String]) async throws {
        if args.contains("--help") || args.isEmpty {
            print("model pull --alias ALIAS | --repo ORG/NAME --revision REV [--data-root PATH]")
            print("model list [--data-root PATH]")
            print("model remove --alias ALIAS [--data-root PATH]")
            return
        }
        let root = RuntimeRoot(url: CredentialCommand.rootURL(args: args))
        try root.prepare()
        let store = ModelStore(root: root)

        switch args[0] {
        case "pull": try await pull(args: args, root: root, store: store)
        case "list": try list(root: root, store: store)
        case "remove": try remove(args: args, root: root, store: store)
        default:
            throw PlatformError(.invalidRequest, detail: "unknown model subcommand")
        }
    }

    /// Declared mlx entries in registry.json, alias -> source. A missing or
    /// empty registry means nothing is declared (pull then only works with
    /// explicit --repo).
    private static func declaredSources(root: RuntimeRoot) throws -> [String: ModelSource] {
        guard let raw = try root.readOwnedJSON(root.registryURL) else { return [:] }
        var out: [String: ModelSource] = [:]
        for entry in try ModelRegistry.parse(raw) {
            if let source = entry.profile.source {
                out[entry.profile.alias] = source
            }
        }
        return out
    }

    private static func pull(args: [String], root: RuntimeRoot,
                             store: ModelStore) async throws {
        let source: ModelSource
        if let alias = value(forFlag: "--alias", in: args) {
            let declared = try declaredSources(root: root)
            guard let found = declared[alias] else {
                throw PlatformError(.notFound,
                                    detail: "no mlx registry entry for alias")
            }
            source = found
        } else if let repo = value(forFlag: "--repo", in: args),
                  let revision = value(forFlag: "--revision", in: args) {
            guard ModelRegistry.isValidRepo(repo), ModelRegistry.isValidRevision(revision) else {
                throw PlatformError(.invalidRequest, detail: "repo/revision malformed")
            }
            source = ModelSource(repo: repo, revision: revision)
        } else {
            throw PlatformError(.invalidRequest, detail: "pull requires --alias or --repo+--revision")
        }

        if store.isReady(source: source) {
            print("already pulled: \(source.repo)@\(source.revision)")
            return
        }
        FileHandle.standardError.write(Data(
            "pulling \(source.repo)@\(source.revision) -> \(store.directory(for: source).path)\n".utf8))
        let reporter = ProgressReporter()
        let manifest = try await store.pull(source: source) { fraction in
            reporter.report(fraction)
        }
        FileHandle.standardError.write(Data("\n".utf8))
        let bytes = manifest.files.reduce(Int64(0)) { $0 + $1.size }
        print("pulled \(manifest.repo)@\(manifest.revision)" +
              (manifest.resolvedRevision.map { " (\($0.prefix(12)))" } ?? "") +
              " \(manifest.files.count) files, \(bytes) bytes")
    }

    private static func list(root: RuntimeRoot, store: ModelStore) throws {
        let declared = try declaredSources(root: root)
        let installed = store.list()
        var installedBySource: [String: ModelStore.InstalledModel] = [:]
        for model in installed {
            installedBySource["\(model.manifest.repo)@\(model.manifest.revision)"] = model
        }
        for (alias, source) in declared.sorted(by: { $0.key < $1.key }) {
            let key = "\(source.repo)@\(source.revision)"
            if let model = installedBySource[key] {
                let bytes = model.manifest.files.reduce(Int64(0)) { $0 + $1.size }
                print("\(alias)\tpulled\t\(key)\t\(bytes) bytes")
            } else {
                print("\(alias)\tnot pulled\t\(key)")
            }
        }
        for model in installed where
            !declared.values.contains(where: {
                "\($0.repo)@\($0.revision)" == "\(model.manifest.repo)@\(model.manifest.revision)"
            }) {
            let bytes = model.manifest.files.reduce(Int64(0)) { $0 + $1.size }
            print("-\tundeclared\t\(model.manifest.repo)@\(model.manifest.revision)\t\(bytes) bytes")
        }
    }

    private static func remove(args: [String], root: RuntimeRoot, store: ModelStore) throws {
        guard let alias = value(forFlag: "--alias", in: args) else {
            throw PlatformError(.invalidRequest, detail: "remove requires --alias")
        }
        let declared = try declaredSources(root: root)
        guard let source = declared[alias] else {
            throw PlatformError(.notFound, detail: "no mlx registry entry for alias")
        }
        try store.remove(source: source)
        print("removed \(source.repo)@\(source.revision)")
    }
}

/// Lock-confined percent reporter for pull progress on stderr; the hub calls
/// back on a @Sendable path so plain captured state is not allowed.
private final class ProgressReporter: @unchecked Sendable {
    private var last = -1
    private let lock = NSLock()

    func report(_ fraction: Double) {
        let pct = Int(fraction * 100)
        lock.lock()
        defer { lock.unlock() }
        guard pct != last else { return }
        last = pct
        FileHandle.standardError.write(Data("\r\(pct)%".utf8))
    }
}
