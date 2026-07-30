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
}
