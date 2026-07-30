import Foundation

/// Xtream panels are PHP-backed: numeric fields arrive as `Int` or `String`
/// (or occasionally `Double`) depending on panel version, and any field may be
/// `null` or absent. These wrappers absorb that variance; unparseable values
/// decode as `nil` rather than failing the whole payload.
@propertyWrapper
public struct FlexibleInt: Codable, Equatable, Sendable {
    public var wrappedValue: Int?

    public init(wrappedValue: Int? = nil) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
        } else if let int = try? container.decode(Int.self) {
            wrappedValue = int
        } else if let double = try? container.decode(Double.self) {
            wrappedValue = Self.int(fromPanelDouble: double)
        } else if let string = try? container.decode(String.self) {
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            wrappedValue = Int(trimmed) ?? Double(trimmed).flatMap(Self.int(fromPanelDouble:))
        } else {
            wrappedValue = nil
        }
    }

    /// The single conversion used for every non-integer numeric input, whether it
    /// arrived as a JSON double or as a string that only parses as one.
    ///
    /// Panel data is untrusted, so anything `Int` cannot represent is rejected as
    /// `nil` instead of trapping: non-finite values (`nan`, `inf`, and string
    /// spellings such as `"NaN"` or `"-infinity"`) and magnitudes outside
    /// `Int.min ... Int.max`, including large exponents like `1e100`.
    ///
    /// Fractional-value policy: fractional values truncate **toward zero**
    /// (`5.7` → `5`, `-5.7` → `-5`), preserving what this decoder has always done
    /// for the `5.0`-style integrals panels actually send. A magnitude below one
    /// therefore decodes as `0` rather than `nil`.
    static func int(fromPanelDouble double: Double) -> Int? {
        guard double.isFinite else { return nil }
        // Truncating first leaves the exactness check to reject range only.
        return Int(exactly: double.rounded(.towardZero))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

@propertyWrapper
public struct FlexibleString: Codable, Equatable, Sendable {
    public var wrappedValue: String?

    public init(wrappedValue: String? = nil) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
        } else if let string = try? container.decode(String.self) {
            wrappedValue = string
        } else if let int = try? container.decode(Int.self) {
            wrappedValue = String(int)
        } else if let double = try? container.decode(Double.self) {
            wrappedValue = String(double)
        } else if let bool = try? container.decode(Bool.self) {
            wrappedValue = String(bool)
        } else {
            wrappedValue = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

// A wrapped property declared as `@FlexibleInt var x: Int?` still requires its
// key to be present by default. These overloads make an absent key decode as
// nil, matching the panels' habit of dropping fields entirely.
public extension KeyedDecodingContainer {
    func decode(_ type: FlexibleInt.Type, forKey key: Key) throws -> FlexibleInt {
        try decodeIfPresent(FlexibleInt.self, forKey: key) ?? FlexibleInt()
    }

    func decode(_ type: FlexibleString.Type, forKey key: Key) throws -> FlexibleString {
        try decodeIfPresent(FlexibleString.self, forKey: key) ?? FlexibleString()
    }
}
