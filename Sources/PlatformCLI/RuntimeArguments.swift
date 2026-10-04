import Foundation
import PlatformCore

/// Shared command-line argument resolution.
enum RuntimeArguments {
    /// `--data-root PATH` (must be absolute) or the default runtime root.
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
