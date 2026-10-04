import Foundation
import PlatformCore
import PlatformServing

/// `acp --agent AGENT_ID [--data-root PATH]`
/// Stdio facade: stdin/stdout carry only newline-delimited JSON-RPC; all
/// diagnostics go to stderr. Connects to the live daemon's private bridge -
/// never starts its own core, store, or model supervisor. The local-trust
/// bridge needs no credential; the daemon marker supplies only the port.
enum ACPCommand {
    static func run(args: [String]) async throws -> Never {
        guard let agentID = value(forFlag: "--agent", in: args), !agentID.isEmpty else {
            throw PlatformError(.invalidRequest, detail: "--agent required")
        }
        let root = RuntimeRoot(url: RuntimeArguments.rootURL(args: args))
        guard let port = try root.readDaemonMarker() else {
            throw PlatformError(.providerUnavailable, detail: "daemon not running or marker missing")
        }
        let bridgeURL = URL(string: "http://127.0.0.1:\(port)/_bridge/acp")!
        FileHandle.standardError.write(Data(
            "acp facade connected to daemon on port \(port)\n".utf8))
        await ACPStdioFacade().run(agentID: agentID, bridgeURL: bridgeURL)
    }
}
