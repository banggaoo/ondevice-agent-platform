import Foundation

/// Random nonces for automatic browser session ids and CSRF values. These
/// are per-session unguessability markers only - the platform issues no API
/// tokens and performs no OS-level secret storage.
public enum SessionNonce {
    /// 32 random bytes rendered as 64 lowercase hex characters.
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        var out = ""
        out.reserveCapacity(64)
        for _ in 0..<4 {
            var value = generator.next()   // UInt64: 8 random bytes per call
            for _ in 0..<8 {
                out += String(format: "%02x", value & 0xff)
                value >>= 8
            }
        }
        return out
    }
}
