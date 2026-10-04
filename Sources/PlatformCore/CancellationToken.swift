import Foundation

/// Cross-layer cancellation handle. A caller (HTTP connection lifetime,
/// ACP session, parent supervisor) owns a token; submissions observe it so
/// peer disconnect or upstream cancellation reaches queued and active work
/// cooperatively. Observers are invoked exactly once, always outside the
/// lock, so a handler may reentrantly register or cancel without deadlock.
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var observers: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        cancelled = true
        let snapshot = Array(observers.values)
        observers.removeAll()
        lock.unlock()
        for handler in snapshot { handler() }
    }

    /// Registers `handler`. If the token is already cancelled the handler
    /// runs once before returning; handlers always run outside the lock.
    @discardableResult
    public func observe(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return id
        }
        observers[id] = handler
        lock.unlock()
        return id
    }

    public func removeObserver(_ id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }
}
