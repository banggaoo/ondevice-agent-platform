import Foundation
import PlatformCore
import PlatformMLX
import PlatformServing

let args = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    print("""
    ondevice-agent-platform - local model and agent serving platform (M1)

    Usage:
      ondevice-agent-platform serve [--data-root PATH] [--port PORT] [--enable-reference-agent] [--enable-apple-model]
      ondevice-agent-platform acp --agent AGENT_ID [--data-root PATH]
      ondevice-agent-platform credential --scope console|model|agent [--data-root PATH]
      ondevice-agent-platform model pull|list|remove [--alias ALIAS | --repo ORG/NAME --revision REV] [--data-root PATH]
      ondevice-agent-platform --help
    """)
}

func fatalError(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

func value(forFlag flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), args.count > index + 1 else { return nil }
    return args[index + 1]
}

guard let command = args.first, !command.hasPrefix("-") || command == "--help" else {
    printUsage()
    exit(args.first == nil ? 0 : 1)
}

switch command {
case "--help", "help":
    printUsage()
case "serve":
    do { try await ServeCommand.run(args: Array(args.dropFirst())) }
    catch let e as PlatformError { fatalError("serve failed: \(e.safeMessage)") }
    catch { fatalError("serve failed: internal error") }
case "acp":
    do { try await ACPCommand.run(args: Array(args.dropFirst())) }
    catch let e as PlatformError { fatalError("acp failed: \(e.safeMessage)") }
    catch { fatalError("acp failed: internal error") }
case "credential":
    do { try CredentialCommand.run(args: Array(args.dropFirst())) }
    catch let e as PlatformError { fatalError("credential failed: \(e.safeMessage)") }
    catch { fatalError("credential failed: internal error") }
case "model":
    do { try await ModelCommand.run(args: Array(args.dropFirst())) }
    catch let e as PlatformError { fatalError("model failed: \(e.safeMessage)") }
    catch { fatalError("model failed: \(error.localizedDescription)") }
default:
    printUsage()
    exit(1)
}
