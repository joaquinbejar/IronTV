import XCTest
@testable import IronTV

/// Exercises the documented isolation model: `SyncedStorage` is immutable
/// after init and safe to use from concurrent tasks (cloud disabled here —
/// the wrapped UserDefaults carries the thread-safety).
final class SyncedStorageConcurrencyTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "SyncedStorageConcurrencyTests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testConcurrentWritesFromManyTasksAllLand() async {
        let storage = SyncedStorage(defaults: defaults, cloud: nil)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    storage.set(index, forKey: "concurrency.key.\(index)")
                }
            }
        }

        for index in 0..<100 {
            XCTAssertEqual(storage.object(forKey: "concurrency.key.\(index)") as? Int, index)
        }
    }

    func testConcurrentReadersAndWritersDoNotCrash() async {
        let storage = SyncedStorage(defaults: defaults, cloud: nil)
        storage.set([1, 2, 3], forKey: "concurrency.array")

        await withTaskGroup(of: Void.self) { group in
            for round in 0..<50 {
                group.addTask { storage.set([round], forKey: "concurrency.array") }
                group.addTask { _ = storage.array(forKey: "concurrency.array") }
                group.addTask { _ = storage.object(forKey: "concurrency.array") }
            }
        }

        XCTAssertNotNil(storage.array(forKey: "concurrency.array"))
    }
}
