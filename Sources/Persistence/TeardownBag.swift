import Foundation

/// Owns NotificationCenter block-observer tokens and an optional repeating
/// timer, and tears them down when it is itself released — so a `@MainActor`
/// owner needs no nonisolated `deinit` that touches non-Sendable state (an
/// error in the Swift 6 language mode).
///
/// Thread-safety: every mutating member takes an internal lock, and the
/// wrapped teardown operations tolerate it — `NotificationCenter.removeObserver`
/// is callable from any thread. `Timer.invalidate` belongs to the scheduling
/// thread; the documented invariant is that timers are set and replaced from
/// the main thread and the bag's owner is a main-actor object released on the
/// main actor, so the `deinit` backstop runs there too.
public final class TeardownBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []
    private var timer: Timer?

    public init() {}

    /// Keeps a NotificationCenter block-observer token alive until removal or
    /// the bag's release.
    public func store(_ token: NSObjectProtocol) {
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    /// Removes every stored observer now. The bag stays usable afterwards.
    public func removeObservers() {
        lock.lock()
        let removed = tokens
        tokens = []
        lock.unlock()
        removed.forEach(NotificationCenter.default.removeObserver(_:))
    }

    /// Replaces the owned timer, invalidating the previous one. Pass `nil` to
    /// just stop. Call from the thread that scheduled the timer.
    public func setTimer(_ newTimer: Timer?) {
        lock.lock()
        let previous = timer
        timer = newTimer
        lock.unlock()
        previous?.invalidate()
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver(_:))
        timer?.invalidate()
    }
}
