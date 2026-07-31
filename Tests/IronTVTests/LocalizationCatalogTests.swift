import XCTest
@testable import IronTV

/// Guards the shape of `Sources/Localizable.xcstrings`: English is the source
/// language, and every key is either explicitly marked do-not-translate
/// (brand names, technical labels, URL examples) or carries a non-empty
/// Spanish translation. A key added without its `es` entry fails here instead
/// of silently shipping English to Spanish users.
final class LocalizationCatalogTests: XCTestCase {

    private struct Catalog: Decodable {
        struct Entry: Decodable {
            struct Localization: Decodable {
                struct StringUnit: Decodable {
                    let state: String
                    let value: String
                }
                let stringUnit: StringUnit
            }
            let shouldTranslate: Bool?
            let localizations: [String: Localization]?
        }
        let sourceLanguage: String
        let strings: [String: Entry]
    }

    private func loadCatalog() throws -> Catalog {
        // The catalog is part of the source tree, not the test bundle;
        // #filePath anchors the lookup for local runs and CI alike.
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // IronTVTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        return try JSONDecoder().decode(Catalog.self, from: data)
    }

    func testEnglishIsTheSourceLanguage() throws {
        let catalog = try loadCatalog()
        XCTAssertEqual(catalog.sourceLanguage, "en")
        XCTAssertFalse(catalog.strings.isEmpty)
    }

    func testEveryTranslatableKeyHasANonEmptySpanishTranslation() throws {
        let catalog = try loadCatalog()
        for (key, entry) in catalog.strings {
            if entry.shouldTranslate == false { continue }
            let spanish = entry.localizations?["es"]?.stringUnit
            XCTAssertNotNil(spanish, "key without a Spanish translation: \(key)")
            guard let spanish else { continue }
            XCTAssertEqual(spanish.state, "translated", "Spanish entry not marked translated: \(key)")
            XCTAssertFalse(
                spanish.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "empty Spanish translation: \(key)"
            )
        }
    }

    /// Format placeholders must survive translation — a missing or extra %@
    /// crashes or garbles the rendered string at runtime.
    func testSpanishTranslationsKeepTheirFormatPlaceholders() throws {
        let catalog = try loadCatalog()
        for (key, entry) in catalog.strings {
            guard let spanish = entry.localizations?["es"]?.stringUnit.value else { continue }
            let keyPlaceholders = key.components(separatedBy: "%@").count - 1
            let esPlaceholders = spanish.components(separatedBy: "%@").count - 1
            XCTAssertEqual(keyPlaceholders, esPlaceholders, "placeholder count differs for: \(key)")
        }
    }
}
