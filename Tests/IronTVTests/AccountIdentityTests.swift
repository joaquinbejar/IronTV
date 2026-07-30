import XCTest
@testable import IronTV

final class AccountIdentityTests: XCTestCase {
    private let account = Account(
        host: URL(string: "http://host.example.com:8080")!,
        username: "user1",
        password: "pass1"
    )

    /// View identity must change on a password rotation, or the browser keeps
    /// serving the old account's client and caches.
    func testRotatingThePasswordChangesTheIdentity() {
        let rotated = Account(host: account.host, username: account.username, password: "pass2")

        XCTAssertNotEqual(account.identity, rotated.identity)
        XCTAssertNotEqual(account.identity.fingerprint, rotated.identity.fingerprint)
    }

    /// …but the preference namespace must not, or the user loses favorites and
    /// their last channel every time they change their password.
    func testRotatingThePasswordKeepsThePreferenceNamespace() {
        let rotated = Account(host: account.host, username: account.username, password: "pass2")

        XCTAssertEqual(account.identity.namespace, rotated.identity.namespace)
    }

    func testTwoUsersOnTheSameHostGetDistinctIdentities() {
        let other = Account(host: account.host, username: "user2", password: account.password)

        XCTAssertNotEqual(account.identity, other.identity)
        XCTAssertNotEqual(account.identity.namespace, other.identity.namespace)
    }

    func testSameHostDifferentPortsAreDistinct() {
        let otherPort = Account(
            host: URL(string: "http://host.example.com:8081")!,
            username: account.username,
            password: account.password
        )

        XCTAssertNotEqual(account.identity, otherPort.identity)
    }

    func testIdentityIsStableAcrossRecomputation() {
        XCTAssertEqual(account.identity, account.identity)
        XCTAssertEqual(account.identity.fingerprint, AccountIdentity(account: account).fingerprint)
    }

    /// The separator matters: without it, host+username boundaries could be
    /// shifted to produce the same digest.
    func testFieldBoundariesCannotBeShiftedIntoACollision() {
        let host = URL(string: "http://h.example.com")!
        let a = Account(host: host, username: "ab", password: "c")
        let b = Account(host: host, username: "a", password: "bc")

        XCTAssertNotEqual(a.identity.fingerprint, b.identity.fingerprint)
    }

    // MARK: - The password must not leak

    func testNothingAboutTheIdentityRevealsThePassword() {
        let secret = "sup3r-s3cret-pass"
        let identity = Account(host: account.host, username: "user1", password: secret).identity

        XCTAssertFalse(identity.namespace.contains(secret))
        XCTAssertFalse(identity.fingerprint.contains(secret))
        XCTAssertFalse(identity.description.contains(secret))
        XCTAssertFalse("\(identity)".contains(secret))
        // The fingerprint is a truncated digest, not an encoding of the input.
        XCTAssertEqual(identity.fingerprint.count, 16)
        XCTAssertTrue(identity.fingerprint.allSatisfy(\.isHexDigit))
    }

    /// The namespace is what preference keys are built from, so it has to stay
    /// free of the password too.
    func testNamespaceIsHostAndUsernameOnly() {
        XCTAssertEqual(account.identity.namespace, "http://host.example.com:8080.user1")
    }

    // MARK: - Storage namespace (digest)

    func testStorageNamespaceSurvivesAPasswordRotation() {
        let rotated = Account(host: account.host, username: account.username, password: "rotated")
        XCTAssertEqual(account.identity.storageNamespace, rotated.identity.storageNamespace)
    }

    func testStorageNamespaceDiffersPerAccount() {
        let other = Account(host: account.host, username: "user2", password: account.password)
        XCTAssertNotEqual(account.identity.storageNamespace, other.identity.storageNamespace)
    }

    /// The whole point of the digest: no account metadata in key names.
    func testStorageNamespaceCarriesNoAccountMetadata() {
        let namespace = account.identity.storageNamespace
        XCTAssertTrue(namespace.hasPrefix("v1."))
        XCTAssertFalse(namespace.contains("host.example.com"))
        XCTAssertFalse(namespace.contains("user1"))
        XCTAssertFalse(namespace.contains(account.password))
        XCTAssertEqual(namespace.dropFirst(3).count, 16)
        XCTAssertTrue(namespace.dropFirst(3).allSatisfy(\.isHexDigit))
    }
}
