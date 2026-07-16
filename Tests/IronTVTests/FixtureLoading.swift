import Foundation
import XCTest

enum FixtureError: Error {
    case notFound(String)
}

extension XCTestCase {
    func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: "json") else {
            throw FixtureError.notFound(name)
        }
        return try Data(contentsOf: url)
    }

    func decodeFixture<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: fixtureData(name))
    }
}
