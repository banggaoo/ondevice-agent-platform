import Foundation
import PlatformCore
import PlatformServing

/// `acp --agent AGENT_ID [--data-root PATH]`
/// Stdio facade: stdin/stdout carry only newline-delimited JSON-RPC; all
/// diagnostics go to stderr. Connects to the live daemon's private bridge -
/// never starts its own core, store, or model supervisor.
enum ACPCommand {
    static func run(args: [String]) async throws -> Never {
        guard let agentID = value(forFlag: "--agent", in: args), !agentID.isEmpty else {
            throw PlatformError(.invalidRequest, detail: "--agent required")
        }
        let root = RuntimeRoot(url: CredentialCommand.rootURL(args: args))
        guard let port = try root.readDaemonMarker() else {
            throw PlatformError(.providerUnavailable, detail: "daemon not running or marker missing")
        }
        let credentials = KeychainCredentialStore()
        guard let secret = try credentials.secret(
            forKey: CredentialKey.key(root: root.url, scope: .agent)),
            let token = String(data: secret, encoding: .utf8) else {
            throw PlatformError(.unauthorized, detail: "agent credential unavailable")
        }
        let bridgeURL = URL(string: "http://127.0.0.1:\(port)/_bridge/acp")!
        FileHandle.standardError.write(Data(
            "acp facade connected to daemon on port \(port)\n".utf8))
        await ACPStdioFacade().run(agentID: agentID, bridgeURL: bridgeURL, token: token)
    }
}
