import Darwin
import Foundation
import PlatformCore
import PlatformMLX

/// `setup [--data-root PATH] [--models a,b | --all | --none] [--pull]`
///
/// First-run bootstrap: prepares the data root, lets the owner choose which
/// curated models to declare in registry.json, and optionally pulls them
/// through the same governed path as `model pull`. Declaring and pulling stay
/// separate acts - selection alone never downloads.
enum SetupCommand {
    static func run(args: [String]) async throws {
        if args.contains("--help") {
            printUsage()
            return
        }
        let root = RuntimeRoot(url: RuntimeArguments.rootURL(args: args))
        try root.prepare()

        let selection = try resolveSelection(args: args)
        try declare(selection: selection, root: root)

        let pull = args.contains("--pull") || (selection.isTTYChoice && promptPull())
        if pull, !selection.models.isEmpty {
            try await pullSelected(selection.models, root: root)
        }
        printNextSteps(selection: selection.models, pulled: pull)
    }

    private struct Selection {
        var models: [CatalogModel]
        var isTTYChoice = false
    }

    private static func printUsage() {
        print("""
        setup [--data-root PATH] [--models ALIAS[,ALIAS...] | --all | --none] [--pull]

        Prepares the data root and declares chosen models in registry.json.
        With no selection flags and an interactive terminal, prints a menu.
        --pull downloads selected artifacts now (same governed path as
        `model pull`); without it, run `model pull --alias ALIAS` later.
        """)
        printCatalog()
    }

    private static func printCatalog() {
        print("\navailable models:")
        for (index, model) in ModelCatalog.entries.enumerated() {
            let gb = String(format: "%.1f", Double(model.approxBytes) / 1_000_000_000)
            print("  \(index + 1)) \(model.alias)\t~\(gb) GB\t\(model.summary)")
        }
        print("  note: apple-foundation-model needs no download - enable at serve time with --enable-apple-model")
    }

    private static func resolveSelection(args: [String]) throws -> Selection {
        if args.contains("--none") { return Selection(models: []) }
        if args.contains("--all") { return Selection(models: ModelCatalog.entries) }
        if let list = value(forFlag: "--models", in: args) {
            var chosen: [CatalogModel] = []
            for raw in list.split(separator: ",") {
                let alias = raw.trimmingCharacters(in: .whitespaces)
                guard let entry = ModelCatalog.entry(alias: alias) else {
                    throw PlatformError(
                        .invalidRequest,
                        detail: "unknown catalog alias: \(alias)")
                }
                chosen.append(entry)
            }
            return Selection(models: chosen)
        }
        guard isatty(STDIN_FILENO) == 1 else {
            throw PlatformError(
                .invalidRequest,
                detail: "no selection - pass --models, --all, or --none")
        }
        var result = Selection(models: interactivePick())
        result.isTTYChoice = true
        return result
    }

    private static func interactivePick() -> [CatalogModel] {
        printCatalog()
        print("\nselect numbers (e.g. 1,2), 'all', or 'none':")
        guard let line = readLine()?.trimmingCharacters(in: .whitespaces) else {
            return []
        }
        if line == "all" { return ModelCatalog.entries }
        if line.isEmpty || line == "none" { return [] }
        var chosen: [CatalogModel] = []
        for part in line.split(separator: ",") {
            guard let n = Int(part.trimmingCharacters(in: .whitespaces)),
                  ModelCatalog.entries.indices.contains(n - 1) else {
                FileHandle.standardError.write(Data("ignored: \(part)\n".utf8))
                continue
            }
            let entry = ModelCatalog.entries[n - 1]
            if !chosen.contains(where: { $0.alias == entry.alias }) {
                chosen.append(entry)
            }
        }
        return chosen
    }

    private static func promptPull() -> Bool {
        print("pull selected models now? [y/N]")
        return readLine()?.trimmingCharacters(in: .whitespaces)
            .lowercased() == "y"
    }

    private static func declare(selection: Selection, root: RuntimeRoot) throws {
        let existing = try root.readOwnedJSON(root.registryURL)
        let merged = try ModelCatalog.mergedRegistry(
            existing: existing, selection: selection.models)
        try root.writeOwnedJSON(merged, to: root.registryURL)
        for model in selection.models {
            print("declared \(model.alias) -> \(model.source.repo)@\(model.source.revision)")
        }
        if selection.models.isEmpty {
            print(existing == nil
                  ? "initialized empty registry at \(root.registryURL.path)"
                  : "registry unchanged")
        }
    }

    private static func pullSelected(_ models: [CatalogModel],
                                     root: RuntimeRoot) async throws {
        let store = ModelStore(root: root)
        for model in models {
            if store.isReady(source: model.source) {
                print("already pulled: \(model.alias)")
                continue
            }
            FileHandle.standardError.write(Data(
                "pulling \(model.source.repo)@\(model.source.revision)\n".utf8))
            let reporter = ProgressReporter()
            let manifest = try await store.pull(source: model.source) { fraction in
                reporter.report(fraction)
            }
            FileHandle.standardError.write(Data("\n".utf8))
            let bytes = manifest.files.reduce(Int64(0)) { $0 + $1.size }
            print("pulled \(model.alias): \(manifest.files.count) files, \(bytes) bytes")
        }
    }

    private static func printNextSteps(selection: [CatalogModel], pulled: Bool) {
        print("\nnext steps:")
        if !selection.isEmpty, !pulled {
            for model in selection {
                print("  ondevice-agent-platform model pull --alias \(model.alias)")
            }
        }
        print("  ondevice-agent-platform serve --enable-apple-model --enable-operator")
        print("  open http://127.0.0.1:8080 for the console")
    }
}
