import Foundation
import PlatformCore
import PlatformMLX
import PlatformServing

/// `serve [--data-root PATH] [--port PORT] [--enable-reference-agent] [--enable-apple-model]`
/// Starts the one shared core and the loopback boundary. Prints the readiness
/// URL and nonsecret diagnostics only - never credentials.
enum ServeCommand {
    /// Serving alias for the opt-in Apple provider route.
    static let appleModelAlias = "apple-foundation-model"

    struct Config {
        var schemaVersion = 1
        var port: UInt16?
        var enableReferenceAgent = false
        var enableAppleModel = false
    }

    static func run(args: [String]) async throws {
        if args.contains("--help") {
            print("serve [--data-root PATH] [--port PORT] [--enable-reference-agent] [--enable-apple-model]")
            return
        }
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
            throw PlatformError(.versionUnsupported, detail: "macOS 27+ required")
        }
        #if !arch(arm64)
        throw PlatformError(.versionUnsupported, detail: "Apple Silicon required")
        #endif

        // Daemon-wide private default: every file created below (db, WAL,
        // config, markers) is owner-only even when the creator applies a
        // default mode rather than an explicit one.
        _ = umask(0o077)

        let root = RuntimeRoot(url: CredentialCommand.rootURL(args: args))
        try root.prepare()
        try root.acquireLock()
        try root.checkStateFiles()

        var config = Config()
        if let raw = try root.readOwnedJSON(root.configURL) {
            guard let object = raw.objectValue else { throw PlatformError(.invalidRequest, detail: "config malformed") }
            for key in object.keys {
                guard ["schemaVersion", "port", "enableReferenceAgent", "enableAppleModel"].contains(key) else {
                    throw PlatformError(.invalidRequest, detail: "unknown config key")
                }
            }
            if let v = object["schemaVersion"]?.intValue {
                guard v == 1 else { throw PlatformError(.versionUnsupported) }
            }
            if let p = object["port"]?.intValue {
                guard p > 0, p <= 65_535 else { throw PlatformError(.invalidRequest, detail: "bad port") }
                config.port = UInt16(p)
            }
            config.enableReferenceAgent = object["enableReferenceAgent"] == .bool(true)
            config.enableAppleModel = object["enableAppleModel"] == .bool(true)
        } else {
            try root.writeOwnedJSON(.object(["schemaVersion": .int(1)]), to: root.configURL)
        }
        if args.contains("--enable-reference-agent") { config.enableReferenceAgent = true }
        if args.contains("--enable-apple-model") { config.enableAppleModel = true }
        if let p = value(forFlag: "--port", in: args), let n = UInt16(p) { config.port = n }

        // Declared model registry: builtin.linear typed-ML entries are
        // validated and loaded; LLM routes stay code-registered behind their
        // own opt-ins. A malformed registry fails startup, never partially
        // loads.
        if try root.readOwnedJSON(root.registryURL) == nil {
            try root.writeOwnedJSON(.object([
                "schemaVersion": .int(1),
                "models": .array([]),
            ]), to: root.registryURL)
        }
        guard let registryJSON = try root.readOwnedJSON(root.registryURL) else {
            throw PlatformError(.storageFailure, detail: "registry unreadable")
        }
        let registryEntries = try ModelRegistry.parse(registryJSON)

        let credentials = KeychainCredentialStore()
        let monitor = NativeResourceMonitor()
        let supervisor = PlatformSupervisor(
            root: root, credentials: credentials, resourceSource: monitor,
            options: .init(
                enableReferenceAgent: config.enableReferenceAgent,
                referenceEchoModelAlias: config.enableAppleModel ? appleModelAlias : nil))
        try await supervisor.start()
        // Every scope must already have a credential; missing scopes fail
        // truthfully rather than minting silently at runtime. The only
        // deliberate mint-and-display path is `credential --scope`.
        var missing: [String] = []
        for scope in CredentialScope.allCases {
            let key = CredentialKey.key(root: root.url, scope: scope)
            if try credentials.secret(forKey: key) == nil {
                missing.append(scope.rawValue)
            }
        }
        guard missing.isEmpty else {
            let hint = "missing credentials for \(missing.joined(separator: ", ")); " +
                "run: ondevice-agent-platform credential --scope <scope>\n"
            FileHandle.standardError.write(Data(hint.utf8))
            throw PlatformError(.unauthorized)
        }
        try await supervisor.loadCredentials()

        // Explicit opt-in only: registers the Apple model profile with a real
        // provider when the device reports availability; otherwise the alias
        // exists but every request returns truthful provider-unavailable.
        if config.enableAppleModel {
            let available = AppleModelAvailability.status() == .available
            await supervisor.registerModel(
                ModelProfile(alias: appleModelAlias,
                             providerID: AppleFoundationProvider.id,
                             kind: .llm, task: "chat",
                             purposes: ["lightweight", "system-integration"],
                             capabilities: ["text"]),
                provider: available ? AppleFoundationProvider() : nil)
            if !available {
                FileHandle.standardError.write(Data((
                    "apple model enabled but device reports unavailable; " +
                    "alias serves provider-unavailable\n").utf8))
            }
        }

        // Registry-declared routes. builtin.linear entries carry their own
        // predictor; mlx entries share one provider that resolves each
        // profile's pinned source to a pulled artifact at request time - a
        // declared-but-unpulled model stays registered and serves
        // providerUnavailable truthfully.
        let mlx = MLXProvider(store: ModelStore(root: root))
        for entry in registryEntries {
            if let predictor = entry.mlPredictor {
                await supervisor.registerModel(entry.profile, predictor: predictor)
            } else {
                await supervisor.registerModel(entry.profile, provider: mlx)
            }
        }

        let sessions = ConsoleSessions(clock: Clock())
        let acp = ACPService(supervisor: supervisor, clock: Clock())
        let port = config.port ?? 8080
        let routerBox = RouterBox()
        let server = HTTPServer { request, respond in
            guard let router = routerBox.router else {
                respond(.error(PlatformError(.internal), status: 500))
                return
            }
            Task { await router.handle(request, respond: respond) }
        }
        try server.start(port: port)
        let boundPort = try server.waitForPort()
        routerBox.assign(Router(supervisor: supervisor, sessions: sessions, acp: acp,
                                port: boundPort, clock: Clock()))
        try root.writeDaemonMarker(port: boundPort)

        var qualifiedNames = registryEntries.compactMap { entry -> String? in
            // Declared-but-unpulled mlx routes are not qualified.
            if let source = entry.profile.source, !mlx.store.isReady(source: source) {
                return nil
            }
            return entry.profile.alias
        }
        if config.enableAppleModel, AppleModelAvailability.status() == .available {
            qualifiedNames.append(appleModelAlias)
        }
        let qualified = qualifiedNames.isEmpty ? "none" : qualifiedNames.sorted().joined(separator: ",")
        print("ready http://127.0.0.1:\(boundPort)")
        FileHandle.standardError.write(Data(
            "ondevice-agent-platform serving on 127.0.0.1:\(boundPort); providers qualified: \(qualified)\n".utf8))

        let shutdown = CancelSignal()
        shutdown.install {
            Task {
                await supervisor.shutdown()
                server.stop()
                root.removeDaemonMarker()
                Foundation.exit(0)
            }
        }
        // Run until signalled.
        while true { try await Task.sleep(for: .seconds(60)) }
    }
}

/// Lock-confined late binding for the router (bound port known after listen).
final class RouterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _router: Router?

    var router: Router? {
        lock.lock()
        defer { lock.unlock() }
        return _router
    }

    func assign(_ router: Router) {
        lock.lock()
        _router = router
        lock.unlock()
    }
}

/// SIGINT/SIGTERM handling; single-shot dispatch on the first signal.
final class CancelSignal: @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()
    /// Sources must be retained: a released source is cancelled and its
    /// handler never runs.
    private var sources: [DispatchSourceSignal] = []

    func install(_ action: @escaping @Sendable () -> Void) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if self.fired { self.lock.unlock(); return }
                self.fired = true
                self.lock.unlock()
                action()
            }
            source.resume()
            sources.append(source)
        }
    }
}
