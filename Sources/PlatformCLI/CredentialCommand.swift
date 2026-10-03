import Foundation
import PlatformCore

/// `credential --scope console|model|agent [--data-root PATH]`
/// The only deliberate token display: prints the secret alone on stdout.
enum CredentialCommand {
    static func run(args: [String]) throws {
        guard let scopeName = value(forFlag: "--scope", in: args),
              let scope = CredentialScope(rawValue: scopeName) else {
            throw PlatformError(.invalidRequest, detail: "--scope console|model|agent required")
        }
        let root = RuntimeRoot(url: rootURL(args: args))
        let store = KeychainCredentialStore()
        let token = try store.ensureSecret(root: root.url, scope: scope)
        // Only the secret goes to stdout - nothing else.
        print(token)
    }

    static func rootURL(args: [String]) -> URL {
        if let path = value(forFlag: "--data-root", in: args) {
            guard path.hasPrefix("/") else {
                FileHandle.standardError.write(Data("--data-root must be absolute\n".utf8))
                exit(1)
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return RuntimeRoot.defaultURL
    }
}
