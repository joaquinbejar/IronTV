import XCTest
@testable import IronTV

final class TeardownBagTests: XCTestCase {

    private let noteName = Notification.Name("TeardownBagTests.probe")

    private func makeCounter() -> (fire: () -> Int, token: NSObjectProtocol) {
        // Boxed on purpose: the closure must observe post-removal silence.
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        let token = NotificationCenter.default.addObserver(
            forName: noteName, object: nil, queue: nil
        ) { _ in counter.value += 1 }
        return ({
            NotificationCenter.default.post(name: self.noteName, object: nil)
            return counter.value
        }, token)
    }

    func testReleasingTheBagRemovesItsObservers() {
        let (fire, token) = makeCounter()
        var bag: TeardownBag? = TeardownBag()
        bag?.store(token)

        XCTAssertEqual(fire(), 1)
        bag = nil
        XCTAssertEqual(fire(), 1, "a released bag must have removed its observers")
    }

    func testRemoveObserversWorksNowAndTheBagStaysUsable() {
        let (fire, token) = makeCounter()
        let bag = TeardownBag()
        bag.store(token)

        XCTAssertEqual(fire(), 1)
        bag.removeObservers()
        XCTAssertEqual(fire(), 1)

        let (fire2, token2) = makeCounter()
        bag.store(token2)
        XCTAssertEqual(fire2(), 1, "the bag must stay usable after a drain")
        bag.removeObservers()
    }

    func testSetTimerInvalidatesThePreviousTimer() {
        let bag = TeardownBag()
        let first = Timer(timeInterval: 3600, repeats: true) { _ in }
        RunLoop.main.add(first, forMode: .common)
        bag.setTimer(first)
        XCTAssertTrue(first.isValid)

        let second = Timer(timeInterval: 3600, repeats: true) { _ in }
        RunLoop.main.add(second, forMode: .common)
        bag.setTimer(second)
        XCTAssertFalse(first.isValid, "replacing the timer must invalidate the previous one")
        XCTAssertTrue(second.isValid)

        bag.setTimer(nil)
        XCTAssertFalse(second.isValid)
    }

    func testReleasingTheBagInvalidatesTheTimer() {
        let timer = Timer(timeInterval: 3600, repeats: true) { _ in }
        RunLoop.main.add(timer, forMode: .common)
        var bag: TeardownBag? = TeardownBag()
        bag?.setTimer(timer)

        bag = nil
        XCTAssertFalse(timer.isValid, "a released bag must have invalidated its timer")
    }

    /// A main-actor owner's deinit is nonisolated: the last release can happen
    /// off the main thread, and the invalidation must hop back to the
    /// scheduling run loop instead of running cross-thread.
    @MainActor
    func testReleasingTheBagOffMainStillInvalidatesOnTheMainRunLoop() async {
        let timer = Timer(timeInterval: 3600, repeats: true) { _ in }
        RunLoop.main.add(timer, forMode: .common)
        var bag: TeardownBag? = TeardownBag()
        bag?.setTimer(timer)

        var transferred: TeardownBag? = bag
        bag = nil
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { [captured = transferred] in
                // The brief sleep guarantees the main-thread reference below
                // has already dropped — the LAST release happens here,
                // off the main thread.
                usleep(10_000)
                _ = captured
                done.resume()
            }
            transferred = nil
        }

        // The hop is async — drain the main queue until it lands.
        for _ in 0..<100 where timer.isValid {
            await Task.yield()
        }
        XCTAssertFalse(timer.isValid, "off-main release must still invalidate on the scheduling run loop")
    }
}
