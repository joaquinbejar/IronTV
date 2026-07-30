import Foundation

/// Owns NotificationCenter block-observer tokens and an optional repeating
/// timer, and tears them down when it is itself released — so a `@MainActor`
/// owner needs no nonisolated `deinit` that touches non-Sendable state (an
/// error in the Swift 6 language mode).
///
/// Thread-safety: every mutating member takes an internal lock, and the
/// wrapped teardown operations tolerate it — `NotificationCenter.removeObserver`
/// is callable from any thread. `Timer.invalidate` belongs to the thread that
/// scheduled the timer (main, for every timer this app creates), and that is
/// **enforced**, not assumed: invalidation always executes on the main
/// thread, hopping there when a release happens elsewhere — a main-actor
/// owner's deinit is nonisolated and can run off-main, and a cross-thread
/// invalidate may leave the timer's input source attached to its run loop.
public final class TeardownBag: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var timer: Timer?

    public init() {}

    /// Keeps a block-observer token alive until removal or the bag's release.
    /// Tokens must be removed from the center that created them, so the pair
    /// is stored together; `center` defaults to `.default`.
    public func store(_ token: NSObjectProtocol, from center: NotificationCenter = .default) {
        lock.lock()
        observations.append((center, token))
        lock.unlock()
    }

    /// Removes every stored observer now. The bag stays usable afterwards.
    public func removeObservers() {
        lock.lock()
        let removed = observations
        observations = []
        lock.unlock()
        removed.forEach { $0.center.removeObserver($0.token) }
    }

    /// Replaces the owned timer, invalidating the previous one. Pass `nil` to
    /// just stop. Timers must be scheduled on the main run loop.
    public func setTimer(_ newTimer: Timer?) {
        lock.lock()
        let previous = timer
        timer = newTimer
        lock.unlock()
        Self.invalidateOnMain(previous)
    }

    /// `Timer` isn't Sendable, but handing it to the main thread — the thread
    /// that scheduled it — for the sole purpose of invalidation is exactly the
    /// contract Timer wants.
    private struct TimerTransfer: @unchecked Sendable {
        let timer: Timer
    }

    private static func invalidateOnMain(_ timer: Timer?) {
        guard let timer else { return }
        if Thread.isMainThread {
            timer.invalidate()
        } else {
            let transfer = TimerTransfer(timer: timer)
            DispatchQueue.main.async { transfer.timer.invalidate() }
        }
    }

    deinit {
        // deinit has exclusive access by definition, but locking keeps the
        // implementation aligned with the documented thread-safety contract.
        lock.lock()
        let observations = self.observations
        let timer = self.timer
        lock.unlock()
        observations.forEach { $0.center.removeObserver($0.token) }
        Self.invalidateOnMain(timer)
    }
}
