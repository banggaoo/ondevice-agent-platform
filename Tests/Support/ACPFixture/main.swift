import Foundation
import PlatformCore
import PlatformServing

// TEST-ONLY ACP stdio fixture. Mirrors the production `acp` facade but takes
// its daemon port from the environment so tests never touch the user's
// runtime root. Not a runtime provider and not built as part of the product
// executable.

func arg(_ flag: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return nil }
    return args[i + 1]
}

let env = ProcessInfo.processInfo.environment
guard let agent = arg("--agent"),
      let portText = env["ACP_FIXTURE_PORT"], let port = UInt16(portText) else {
    FileHandle.standardError.write(Data("acp-fixture: missing --agent/ACP_FIXTURE_PORT\n".utf8))
    exit(2)
}

let bridgeURL = URL(string: "http://127.0.0.1:\(port)/_bridge/acp")!
await ACPStdioFacade().run(agentID: agent, bridgeURL: bridgeURL)
